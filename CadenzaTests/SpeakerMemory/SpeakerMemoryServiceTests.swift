import Foundation
import Testing
@testable import Cadenza

// MARK: - Test Helpers

/// Creates a normalized unit vector pointing in one direction.
/// `angle` in radians rotates a 2D unit vector; remaining dimensions are zero.
private func makeEmbedding(angle: Float, dimension: Int = 4) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[0] = cos(angle)
    v[1] = sin(angle)
    return v
}

private func makeWindow(
    speakerIndex: Int,
    embedding: [Float],
    nonOverlapRatio: Float = 0.8,
    windowStart: Float = 0
) -> SpeakerWindowEmbedding {
    SpeakerWindowEmbedding(
        rawSpeakerIndex: speakerIndex,
        windowStart: windowStart,
        windowEnd: windowStart + 10,
        embedding: embedding,
        nonOverlapRatio: nonOverlapRatio,
        modelVersion: "test-v1"
    )
}

@MainActor
private func makeSpeakerMemoryStore() throws -> RecordingsStore {
    let container = try RecordingsStore.makeContainer(inMemory: true)
    return RecordingsStore(modelContainer: container)
}

private struct FixedSpeakerEmbeddingExtractor: SpeakerEmbeddingExtractorProtocol {
    let result: SpeakerEmbeddingResult
    let modelVersion = "test-v1"

    func extractEmbeddings(from audioURL: URL) async throws -> SpeakerEmbeddingResult {
        result
    }
}

// MARK: - L2 Normalization

@Suite("SpeakerMemoryService.l2Normalize")
struct L2NormalizeTests {
    @Test func normalizesNonZeroVector() {
        let v: [Float] = [3, 4, 0, 0]
        let n = SpeakerMemoryService.l2Normalize(v)
        let magnitude = sqrt(n.reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 1e-5)
        #expect(abs(n[0] - 0.6) < 1e-5)
        #expect(abs(n[1] - 0.8) < 1e-5)
    }

    @Test func zeroVectorReturnsZero() {
        let v: [Float] = [0, 0, 0, 0]
        let n = SpeakerMemoryService.l2Normalize(v)
        #expect(n == [0, 0, 0, 0])
    }
}

// MARK: - Cosine Similarity

@Suite("SpeakerMemoryService.cosineSimilarity")
struct CosineSimilarityTests {
    @Test func identicalVectorsReturnOne() {
        let v = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        let score = SpeakerMemoryService.cosineSimilarity(v, v)
        #expect(abs(score - 1.0) < 1e-5)
    }

    @Test func orthogonalVectorsReturnZero() {
        let a = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        let b = SpeakerMemoryService.l2Normalize([0, 1, 0, 0])
        let score = SpeakerMemoryService.cosineSimilarity(a, b)
        #expect(abs(score) < 1e-5)
    }

    @Test func oppositeVectorsReturnNegativeOne() {
        let a = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        let b = SpeakerMemoryService.l2Normalize([-1, 0, 0, 0])
        let score = SpeakerMemoryService.cosineSimilarity(a, b)
        #expect(abs(score + 1.0) < 1e-5)
    }
}

// MARK: - Centroid Computation

@Suite("SpeakerMemoryService.computeCentroid")
struct CentroidTests {
    @Test func centroidOfIdenticalVectors() {
        let v: [Float] = [1, 0, 0, 0]
        let centroid = SpeakerMemoryService.computeCentroid([v, v, v])
        let score = SpeakerMemoryService.cosineSimilarity(
            SpeakerMemoryService.l2Normalize(centroid),
            SpeakerMemoryService.l2Normalize(v)
        )
        #expect(abs(score - 1.0) < 1e-5)
    }

    @Test func centroidDirectionBetweenTwoVectors() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        let centroid = SpeakerMemoryService.computeCentroid([a, b])
        // Centroid of [1,0] and [0,1] should be [0.5, 0.5, 0, 0]
        #expect(abs(centroid[0] - 0.5) < 1e-5)
        #expect(abs(centroid[1] - 0.5) < 1e-5)
    }

    @Test func emptyInputReturnsEmpty() {
        let centroid = SpeakerMemoryService.computeCentroid([])
        #expect(centroid.isEmpty)
    }
}

// MARK: - Quality Gating

@Suite("SpeakerMemoryService.qualityGating")
struct QualityGatingTests {
    @Test func dropsBelowNonOverlapThreshold() {
        // All windows have nonOverlapRatio 0.3, below the 0.6 minimum
        let windows = [
            makeWindow(speakerIndex: 0, embedding: [1, 0, 0, 0], nonOverlapRatio: 0.3),
            makeWindow(speakerIndex: 0, embedding: [1, 0, 0, 0], nonOverlapRatio: 0.4),
        ]
        let service = SpeakerMemoryService(config: .default)
        let accepted = service.filterWindows(windows, minimumNonOverlapRatio: 0.6)
        #expect(accepted.isEmpty)
    }

    @Test func keepAboveNonOverlapThreshold() {
        let windows = [
            makeWindow(speakerIndex: 0, embedding: [1, 0, 0, 0], nonOverlapRatio: 0.7),
            makeWindow(speakerIndex: 0, embedding: [1, 0, 0, 0], nonOverlapRatio: 0.9),
        ]
        let service = SpeakerMemoryService(config: .default)
        let accepted = service.filterWindows(windows, minimumNonOverlapRatio: 0.6)
        #expect(accepted.count == 2)
    }
}

// MARK: - Atomic Analysis Persistence

@Suite("SpeakerMemoryService.atomicPersistence", .serialized)
struct SpeakerMemoryAtomicPersistenceTests {
    @Test @MainActor
    func analyzePersistsAllCentroidsThroughTheBatchPath() async throws {
        let store = try makeSpeakerMemoryStore()
        await store.setSpeakerMemoryConsentForTesting(true)
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let revision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "One Two",
            segments: [
                TranscriptEntry(startTime: 0, endTime: 10, text: "One", speaker: "Speaker 1"),
                TranscriptEntry(startTime: 10, endTime: 20, text: "Two", speaker: "Speaker 2")
            ],
            language: "en",
            tags: []
        ))
        let extractor = Self.makeTwoSpeakerExtractor()
        let service = SpeakerMemoryService(config: Self.testConfig)

        try await service.analyze(
            recordingID: recordingID,
            audioURL: URL(fileURLWithPath: "/tmp/not-read-by-fixed-extractor.m4a"),
            speakerSpans: [
                SpeakerLabelSpan(label: "Speaker 1", startTime: 0, endTime: 10),
                SpeakerLabelSpan(label: "Speaker 2", startTime: 10, endTime: 20)
            ],
            speakerIdentityRevision: revision,
            store: store,
            extractor: extractor
        )

        let samples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(samples.count == 2)
        #expect(Set(samples.map(\.rawLabel)) == ["Speaker 1", "Speaker 2"])
    }

#if DEBUG
    @Test @MainActor
    func analyzeBatchSaveFailureLeavesNoPartialSamples() async throws {
        let store = try makeSpeakerMemoryStore()
        await store.setSpeakerMemoryConsentForTesting(true)
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let revision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "One Two",
            segments: [
                TranscriptEntry(startTime: 0, endTime: 10, text: "One", speaker: "Speaker 1"),
                TranscriptEntry(startTime: 10, endTime: 20, text: "Two", speaker: "Speaker 2")
            ],
            language: "en",
            tags: []
        ))
        let service = SpeakerMemoryService(config: Self.testConfig)
        await store._test_failNextSave()

        try await service.analyze(
            recordingID: recordingID,
            audioURL: URL(fileURLWithPath: "/tmp/not-read-by-fixed-extractor.m4a"),
            speakerSpans: [
                SpeakerLabelSpan(label: "Speaker 1", startTime: 0, endTime: 10),
                SpeakerLabelSpan(label: "Speaker 2", startTime: 10, endTime: 20)
            ],
            speakerIdentityRevision: revision,
            store: store,
            extractor: Self.makeTwoSpeakerExtractor()
        )

        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).isEmpty)
    }
#endif

    private static let testConfig = SpeakerMemoryConfig(
        minimumSpeechSeconds: 1,
        minimumNonOverlapRatio: 0.5,
        topScoreThresholdMultiSample: 0.5,
        topScoreThresholdSingleSample: 0.6,
        autoApplyThreshold: 0.75,
        runnerUpMargin: 0.05
    )

    private static func makeTwoSpeakerExtractor() -> FixedSpeakerEmbeddingExtractor {
        FixedSpeakerEmbeddingExtractor(result: SpeakerEmbeddingResult(
            embeddings: [
                makeWindow(speakerIndex: 0, embedding: [1, 0, 0, 0], nonOverlapRatio: 1, windowStart: 0),
                makeWindow(speakerIndex: 1, embedding: [0, 1, 0, 0], nonOverlapRatio: 1, windowStart: 10)
            ],
            speakerActivitySpans: [
                SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 10),
                SpeakerAssignmentSpan(speakerID: 1, startTime: 10, endTime: 20)
            ],
            speakerCount: 2,
            embeddingDimension: 4,
            modelVersion: "test-v1"
        ))
    }
}

// MARK: - Speaker Index Mapping

@Suite("SpeakerMemoryService.speakerIndexMapping")
struct SpeakerIndexMappingTests {
    @Test func mapsByTranscriptTimestamps() {
        let service = SpeakerMemoryService(config: .default)
        let centroids = [
            SpeakerMemoryService.SpeakerCentroidResult(
                rawSpeakerIndex: 0,
                centroid: [1, 0, 0, 0],
                windowCount: 2,
                totalSpeechSeconds: 20,
                averageNonOverlapRatio: 0.9
            ),
            SpeakerMemoryService.SpeakerCentroidResult(
                rawSpeakerIndex: 1,
                centroid: [0, 1, 0, 0],
                windowCount: 2,
                totalSpeechSeconds: 20,
                averageNonOverlapRatio: 0.9
            ),
        ]
        let activity = [
            SpeakerAssignmentSpan(speakerID: 0, startTime: 90, endTime: 115),
            SpeakerAssignmentSpan(speakerID: 1, startTime: 0, endTime: 20)
        ]
        let spans: [SpeakerLabelSpan] = [
            SpeakerLabelSpan(label: "Speaker A", startTime: 0, endTime: 20),
            SpeakerLabelSpan(label: "Speaker B", startTime: 90, endTime: 115),
        ]

        let mapping = service.buildSpeakerIndexToLabelMapping(
            centroids: centroids,
            speakerActivitySpans: activity,
            speakerSpans: spans
        )

        #expect(mapping[0] == "Speaker B")
        #expect(mapping[1] == "Speaker A")
    }

    @Test func exactActivitySpansAvoidInterleavedEnvelopeSwap() {
        let service = SpeakerMemoryService(config: .default)
        let centroids = [
            SpeakerMemoryService.SpeakerCentroidResult(
                rawSpeakerIndex: 0,
                centroid: [1, 0, 0, 0],
                windowCount: 2,
                totalSpeechSeconds: 20,
                averageNonOverlapRatio: 0.9
            ),
            SpeakerMemoryService.SpeakerCentroidResult(
                rawSpeakerIndex: 1,
                centroid: [0, 1, 0, 0],
                windowCount: 2,
                totalSpeechSeconds: 20,
                averageNonOverlapRatio: 0.9
            )
        ]
        // Speaker 0 talks briefly at both ends while Speaker 1 owns the long
        // middle turn. A first-to-last envelope would incorrectly map Speaker 0
        // to label 2; exact activity must retain the real identities.
        let activity = [
            SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 4),
            SpeakerAssignmentSpan(speakerID: 1, startTime: 4, endTime: 20),
            SpeakerAssignmentSpan(speakerID: 0, startTime: 20, endTime: 24)
        ]
        let spans: [SpeakerLabelSpan] = [
            SpeakerLabelSpan(label: "Speaker 1", startTime: 0, endTime: 4),
            SpeakerLabelSpan(label: "Speaker 2", startTime: 4, endTime: 20),
            SpeakerLabelSpan(label: "Speaker 1", startTime: 20, endTime: 24)
        ]

        let mapping = service.buildSpeakerIndexToLabelMapping(
            centroids: centroids,
            speakerActivitySpans: activity,
            speakerSpans: spans
        )

        #expect(mapping[0] == "Speaker 1")
        #expect(mapping[1] == "Speaker 2")
    }

    @Test func evenlySplitActivityRemainsUnmatched() {
        let service = SpeakerMemoryService(config: .default)
        let centroids = [makeCentroid(speakerIndex: 0)]
        let activity = [SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 10)]
        let spans: [SpeakerLabelSpan] = [
            SpeakerLabelSpan(label: "Speaker A", startTime: 0, endTime: 5),
            SpeakerLabelSpan(label: "Speaker B", startTime: 5, endTime: 10)
        ]

        let mapping = service.buildSpeakerIndexToLabelMapping(
            centroids: centroids,
            speakerActivitySpans: activity,
            speakerSpans: spans
        )

        #expect(mapping.isEmpty)
    }

    @Test func tinyBoundaryOverlapRemainsUnmatched() {
        let service = SpeakerMemoryService(config: .default)
        let centroids = [makeCentroid(speakerIndex: 0)]
        let activity = [SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 20)]
        let spans: [SpeakerLabelSpan] = [
            SpeakerLabelSpan(label: "Speaker A", startTime: 19.5, endTime: 20)
        ]

        let mapping = service.buildSpeakerIndexToLabelMapping(
            centroids: centroids,
            speakerActivitySpans: activity,
            speakerSpans: spans
        )

        #expect(mapping.isEmpty)
    }

    @Test func overClusteredVoiceDoesNotConsumeAnotherIdentity() {
        let service = SpeakerMemoryService(config: .default)
        let centroids = (0..<3).map { makeCentroid(speakerIndex: $0) }
        let activity = [
            SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 10),
            SpeakerAssignmentSpan(speakerID: 1, startTime: 10, endTime: 20),
            SpeakerAssignmentSpan(speakerID: 2, startTime: 20, endTime: 30)
        ]
        let spans: [SpeakerLabelSpan] = [
            SpeakerLabelSpan(label: "Speaker A", startTime: 0, endTime: 20),
            SpeakerLabelSpan(label: "Speaker B", startTime: 20, endTime: 30)
        ]

        let mapping = service.buildSpeakerIndexToLabelMapping(
            centroids: centroids,
            speakerActivitySpans: activity,
            speakerSpans: spans
        )

        #expect(mapping.values.filter { $0 == "Speaker A" }.count == 1)
        #expect(mapping[2] == "Speaker B")
        #expect(mapping.count == 2)
    }

    @Test func largeAssignmentUsesGlobalOptimumInsteadOfGreedyChoice() {
        let speakerIDs = Array(0..<9)
        let labels = (0..<9).map { "L\($0)" }
        var scores = Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, [String: Float]()) })
        scores[0] = ["L0": 10, "L1": 9]
        scores[1] = ["L0": 9]
        for index in 2..<9 {
            scores[index] = ["L\(index)": 5]
        }

        let mapping = SpeakerMemoryService.maximumWeightMapping(
            speakerIDs: speakerIDs,
            labels: labels,
            scores: scores
        )

        #expect(mapping[0] == "L1")
        #expect(mapping[1] == "L0")
        for index in 2..<9 {
            #expect(mapping[index] == "L\(index)")
        }
    }

    private func makeCentroid(speakerIndex: Int) -> SpeakerMemoryService.SpeakerCentroidResult {
        SpeakerMemoryService.SpeakerCentroidResult(
            rawSpeakerIndex: speakerIndex,
            centroid: [1, 0, 0, 0],
            windowCount: 2,
            totalSpeechSeconds: 20,
            averageNonOverlapRatio: 0.9
        )
    }
}

// MARK: - Threshold Matching

@Suite("SpeakerMemoryService.matchSpeaker")
struct MatchSpeakerTests {
    private static let profileAlice = UUID()
    private static let profileBob = UUID()

    @Test func noConfirmedSamplesReturnsNil() {
        let service = SpeakerMemoryService(config: .init(
            minimumSpeechSeconds: 15,
            minimumNonOverlapRatio: 0.6,
            topScoreThresholdMultiSample: 0.78,
            topScoreThresholdSingleSample: 0.82,
            autoApplyThreshold: 0.90,
            runnerUpMargin: 0.05
        ))
        let centroid = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        let result = service.matchSpeaker(
            centroid: centroid,
            confirmedSamples: [],
            currentModelVersion: "test-v1"
        )
        #expect(result == nil)
    }

    @Test func strongMatchWithTwoSamplesReturnsSuggestion() {
        let service = SpeakerMemoryService(config: .init(
            minimumSpeechSeconds: 15,
            minimumNonOverlapRatio: 0.6,
            topScoreThresholdMultiSample: 0.78,
            topScoreThresholdSingleSample: 0.82,
            autoApplyThreshold: 0.90,
            runnerUpMargin: 0.05
        ))

        let aliceEmb = SpeakerMemoryService.l2Normalize([1, 0.05, 0, 0])
        let centroid = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        // Cosine between centroid and aliceEmb ≈ 0.9988 (very close)

        let samples: [SpeakerMemoryService.ProfileSample] = [
            .init(profileID: Self.profileAlice, centroid: aliceEmb, modelVersion: "test-v1", sampleCount: 2),
        ]

        let result = service.matchSpeaker(
            centroid: centroid,
            confirmedSamples: samples,
            currentModelVersion: "test-v1"
        )
        #expect(result?.profileID == Self.profileAlice)
    }

    @Test func belowThresholdReturnsNil() {
        let service = SpeakerMemoryService(config: .init(
            minimumSpeechSeconds: 15,
            minimumNonOverlapRatio: 0.6,
            topScoreThresholdMultiSample: 0.78,
            topScoreThresholdSingleSample: 0.82,
            autoApplyThreshold: 0.90,
            runnerUpMargin: 0.05
        ))

        // Orthogonal vectors → cosine ≈ 0, well below threshold
        let aliceEmb = SpeakerMemoryService.l2Normalize([0, 1, 0, 0])
        let centroid = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])

        let samples: [SpeakerMemoryService.ProfileSample] = [
            .init(profileID: Self.profileAlice, centroid: aliceEmb, modelVersion: "test-v1", sampleCount: 2),
        ]

        let result = service.matchSpeaker(
            centroid: centroid,
            confirmedSamples: samples,
            currentModelVersion: "test-v1"
        )
        #expect(result == nil)
    }

    @Test func insufficientMarginReturnsNil() {
        let service = SpeakerMemoryService(config: .init(
            minimumSpeechSeconds: 15,
            minimumNonOverlapRatio: 0.6,
            topScoreThresholdMultiSample: 0.78,
            topScoreThresholdSingleSample: 0.82,
            autoApplyThreshold: 0.90,
            runnerUpMargin: 0.05
        ))

        // Two profiles with very similar embeddings to the centroid → small gap
        let centroid = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        let aliceEmb = SpeakerMemoryService.l2Normalize([1, 0.1, 0, 0])
        let bobEmb = SpeakerMemoryService.l2Normalize([1, 0.12, 0, 0])
        // Both are very close to centroid; gap between top-1 and top-2 < 0.05

        let samples: [SpeakerMemoryService.ProfileSample] = [
            .init(profileID: Self.profileAlice, centroid: aliceEmb, modelVersion: "test-v1", sampleCount: 2),
            .init(profileID: Self.profileBob, centroid: bobEmb, modelVersion: "test-v1", sampleCount: 2),
        ]

        let result = service.matchSpeaker(
            centroid: centroid,
            confirmedSamples: samples,
            currentModelVersion: "test-v1"
        )
        #expect(result == nil)
    }

    @Test func singleSampleUsesHigherThreshold() {
        let service = SpeakerMemoryService(config: .init(
            minimumSpeechSeconds: 15,
            minimumNonOverlapRatio: 0.6,
            topScoreThresholdMultiSample: 0.78,
            topScoreThresholdSingleSample: 0.82,
            autoApplyThreshold: 0.90,
            runnerUpMargin: 0.05
        ))

        // Score of ~0.80 — passes multi-sample threshold (0.78) but fails single-sample (0.82)
        let angle: Float = 0.6435   // acos(0.80) ≈ 0.6435 radians
        let centroid = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        let aliceEmb = SpeakerMemoryService.l2Normalize([cos(angle), sin(angle), 0, 0])

        let samples: [SpeakerMemoryService.ProfileSample] = [
            .init(profileID: Self.profileAlice, centroid: aliceEmb, modelVersion: "test-v1", sampleCount: 1),
        ]

        let result = service.matchSpeaker(
            centroid: centroid,
            confirmedSamples: samples,
            currentModelVersion: "test-v1"
        )
        #expect(result == nil)
    }

    @Test func modelVersionMismatchExcluded() {
        let service = SpeakerMemoryService(config: .default)

        let centroid = SpeakerMemoryService.l2Normalize([1, 0, 0, 0])
        let aliceEmb = centroid  // identical → score 1.0

        let samples: [SpeakerMemoryService.ProfileSample] = [
            .init(profileID: Self.profileAlice, centroid: aliceEmb, modelVersion: "old-v0", sampleCount: 3),
        ]

        let result = service.matchSpeaker(
            centroid: centroid,
            confirmedSamples: samples,
            currentModelVersion: "test-v1"
        )
        #expect(result == nil)
    }
}
