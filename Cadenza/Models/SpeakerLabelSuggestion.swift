import Foundation

struct SpeakerLabelSuggestion: Codable, Sendable {
    var rawLabel: String
    var profileID: UUID
    var score: Float
    var strategy: String
    var modelVersion: String
    var generatedAt: Date
}
