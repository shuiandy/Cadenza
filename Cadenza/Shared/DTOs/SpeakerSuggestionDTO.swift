import Foundation

struct SpeakerLabelSuggestionDTO: Codable, Sendable {
    var rawLabel: String
    var profileID: UUID
    var profileName: String
    var score: Float
    var strategy: String
}
