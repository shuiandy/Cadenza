import Foundation
import SwiftData

@Model
final class SpeakerVoiceSample {
    #Index<SpeakerVoiceSample>([\.recordingID], [\.modelVersion])

    var recordingID: UUID
    var rawLabel: String
    var profile: SpeakerProfile?
    var embeddingData: Data
    var embeddingDimension: Int
    var sampleDuration: TimeInterval
    var nonOverlapRatio: Float
    var qualityScore: Float
    var modelVersion: String
    var createdAt: Date

    init(
        recordingID: UUID,
        rawLabel: String,
        profile: SpeakerProfile? = nil,
        embeddingData: Data,
        embeddingDimension: Int,
        sampleDuration: TimeInterval,
        nonOverlapRatio: Float,
        qualityScore: Float,
        modelVersion: String
    ) {
        self.recordingID = recordingID
        self.rawLabel = rawLabel
        self.profile = profile
        self.embeddingData = embeddingData
        self.embeddingDimension = embeddingDimension
        self.sampleDuration = sampleDuration
        self.nonOverlapRatio = nonOverlapRatio
        self.qualityScore = qualityScore
        self.modelVersion = modelVersion
        self.createdAt = Date()
    }

    /// Deserialize embedding from Data.
    var embedding: [Float] {
        embeddingData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Serialize a Float array to Data.
    static func serializeEmbedding(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
