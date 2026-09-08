import Foundation
import SpeakerKit

// MARK: - App-owned embedding types

struct SpeakerWindowEmbedding: Sendable {
    let rawSpeakerIndex: Int
    let windowStart: Float        // seconds (approximated from windowIndex)
    let windowEnd: Float          // seconds
    let embedding: [Float]
    let nonOverlapRatio: Float
    let modelVersion: String
}

struct SpeakerEmbeddingResult: Sendable {
    let embeddings: [SpeakerWindowEmbedding]
    let speakerActivitySpans: [SpeakerAssignmentSpan]
    let speakerCount: Int
    let embeddingDimension: Int
    let modelVersion: String
}

// MARK: - Extractor protocol

protocol SpeakerEmbeddingExtractorProtocol: Sendable {
    func extractEmbeddings(from audioURL: URL) async throws -> SpeakerEmbeddingResult
    var modelVersion: String { get }
}

// MARK: - SpeakerKit adapter

final class SpeakerKitEmbeddingExtractor: SpeakerEmbeddingExtractorProtocol, @unchecked Sendable {
    static let currentModelVersion = "pyannote-wespeaker-voxceleb-v0.17"
    let modelVersion = currentModelVersion

    func extractEmbeddings(from audioURL: URL) async throws -> SpeakerEmbeddingResult {
        let diarizationResult = try await MainActor.run {
            SpeakerDiarizer.shared
        }.diarize(audioURL: audioURL)
        return Self.makeResult(from: diarizationResult, modelVersion: modelVersion)
    }

    /// Maps a SpeakerKit result into the app-owned embedding result. Shared by
    /// the live extractor and the precomputed path so both produce identical
    /// spans and embeddings for the same diarization.
    nonisolated static func makeResult(
        from diarizationResult: DiarizationResult,
        modelVersion: String = currentModelVersion
    ) -> SpeakerEmbeddingResult {
        let speakerActivitySpans = diarizationResult.segments.compactMap { segment -> SpeakerAssignmentSpan? in
            let speakerID: Int
            switch segment.speaker {
            case .speakerId(let id):
                speakerID = id
            case .multiple(let ids) where ids.count == 1:
                speakerID = ids[0]
            case .multiple, .noMatch:
                return nil
            }
            return SpeakerAssignmentSpan(
                speakerID: speakerID,
                startTime: TimeInterval(segment.startTime),
                endTime: TimeInterval(segment.endTime)
            )
        }

        guard let rawEmbeddings = diarizationResult.windowEmbeddings, !rawEmbeddings.isEmpty else {
            return SpeakerEmbeddingResult(
                embeddings: [],
                speakerActivitySpans: speakerActivitySpans,
                speakerCount: diarizationResult.speakerCount,
                embeddingDimension: 0,
                modelVersion: modelVersion
            )
        }

        let dimension = rawEmbeddings[0].embedding.count
        NSLog("[SpeakerMemory] Using raw embeddings (dim=%d) for cross-recording matching", dimension)

        let windowDuration: Float = 10.0
        let embeddings = rawEmbeddings.map { raw in
            SpeakerWindowEmbedding(
                rawSpeakerIndex: raw.speakerIndex,
                windowStart: Float(raw.windowIndex),
                windowEnd: Float(raw.windowIndex) + windowDuration,
                embedding: raw.embedding,
                nonOverlapRatio: raw.nonOverlappedFrameRatio,
                modelVersion: modelVersion
            )
        }

        return SpeakerEmbeddingResult(
            embeddings: embeddings,
            speakerActivitySpans: speakerActivitySpans,
            speakerCount: diarizationResult.speakerCount,
            embeddingDimension: dimension,
            modelVersion: modelVersion
        )
    }
}

/// Reuses the diarization the transcription pass already ran on this audio
/// revision. Speaker memory used to call `diarize` a second time on the same
/// file: one more full decode into a Float array and one more complete
/// segmenter plus embedder inference, serialized behind the app-wide gate, to
/// obtain window embeddings the first run had computed and discarded.
struct PrecomputedSpeakerEmbeddingExtractor: SpeakerEmbeddingExtractorProtocol {
    let result: SpeakerEmbeddingResult
    var modelVersion: String { result.modelVersion }

    func extractEmbeddings(from audioURL: URL) async throws -> SpeakerEmbeddingResult {
        result
    }
}
