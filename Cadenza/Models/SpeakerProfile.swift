import Foundation
import SwiftData

@Model
final class SpeakerProfile {
    var id: UUID
    var displayName: String
    var aliases: [String]
    var notes: String
    var teamOrOrg: String?
    var createdAt: Date
    var lastSeenAt: Date?

    @Relationship(deleteRule: .nullify, inverse: \SpeakerVoiceSample.profile)
    var voiceSamples: [SpeakerVoiceSample]?

    init(displayName: String, notes: String = "", teamOrOrg: String? = nil) {
        self.id = UUID()
        self.displayName = displayName
        self.aliases = []
        self.notes = notes
        self.teamOrOrg = teamOrOrg
        self.createdAt = Date()
        self.lastSeenAt = nil
    }
}
