import Foundation
import SpeakerKit
import Testing
@testable import Cadenza

@Suite("Precomputed speaker embedding extractor")
struct PrecomputedSpeakerEmbeddingExtractorTests {

    private func diarization() -> DiarizationResult {
        var result = DiarizationResult(
            speakerCount: 2,
            totalFrames: 1_000,
            frameRate: 100,
            segments: [
                SpeakerSegment(speaker: .speakerId(0), startTime: 0, endTime: 4.5, frameRate: 100),
                SpeakerSegment(speaker: .multiple([1]), startTime: 4.5, endTime: 9, frameRate: 100),
                SpeakerSegment(speaker: .multiple([0, 1]), startTime: 9, endTime: 10, frameRate: 100),
                SpeakerSegment(speaker: .noMatch, startTime: 10, endTime: 11, frameRate: 100),
            ]
        )
        result.windowEmbeddings = [
            PublicSpeakerEmbedding(embedding: [1, 0, 0], speakerIndex: 0, windowIndex: 0, nonOverlappedFrameRatio: 0.9),
            PublicSpeakerEmbedding(embedding: [0, 1, 0], speakerIndex: 1, windowIndex: 1, nonOverlappedFrameRatio: 0.8),
        ]
        return result
    }

    @Test func mappingMatchesTheLiveExtractorContract() {
        let mapped = SpeakerKitEmbeddingExtractor.makeResult(from: diarization(), modelVersion: "v-test")

        // Single-speaker segments become spans; overlaps and no-match are dropped.
        #expect(mapped.speakerActivitySpans.map(\.speakerID) == [0, 1])
        #expect(mapped.speakerActivitySpans.map(\.startTime) == [0, 4.5])
        #expect(mapped.speakerActivitySpans.map(\.endTime) == [4.5, 9])
        #expect(mapped.speakerCount == 2)
        #expect(mapped.embeddingDimension == 3)
        #expect(mapped.modelVersion == "v-test")
        #expect(mapped.embeddings.map(\.rawSpeakerIndex) == [0, 1])
        #expect(mapped.embeddings.map(\.windowStart) == [0, 1])
        #expect(mapped.embeddings.map(\.windowEnd) == [10, 11])
        #expect(mapped.embeddings.map(\.nonOverlapRatio) == [0.9, 0.8])
        #expect(mapped.embeddings.allSatisfy { $0.modelVersion == "v-test" })
    }

    @Test func precomputedExtractorReturnsItsResultWithoutTouchingAudio() async throws {
        let mapped = SpeakerKitEmbeddingExtractor.makeResult(from: diarization())
        let extractor = PrecomputedSpeakerEmbeddingExtractor(result: mapped)
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")

        let result = try await extractor.extractEmbeddings(from: missing)
        #expect(result.embeddings.count == mapped.embeddings.count)
        #expect(result.speakerActivitySpans.count == mapped.speakerActivitySpans.count)
        #expect(extractor.modelVersion == SpeakerKitEmbeddingExtractor.currentModelVersion)
    }

    @Test func missingEmbeddingsStillYieldSpans() {
        var bare = diarization()
        bare.windowEmbeddings = nil
        let mapped = SpeakerKitEmbeddingExtractor.makeResult(from: bare)
        #expect(mapped.embeddings.isEmpty)
        #expect(mapped.embeddingDimension == 0)
        #expect(mapped.speakerActivitySpans.count == 2)
    }
}
