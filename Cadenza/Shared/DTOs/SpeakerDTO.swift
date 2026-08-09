import Foundation

struct SpeakerProfileDTO: Codable, Sendable, Identifiable {
    let id: UUID
    var displayName: String
    var aliases: [String]
    var notes: String
    var teamOrOrg: String?
    var createdAt: Date
    var lastSeenAt: Date?
}

struct SpeakerLabelMappingDTO: Codable, Sendable {
    var rawLabel: String
    var profileID: UUID
    var profileName: String
}
