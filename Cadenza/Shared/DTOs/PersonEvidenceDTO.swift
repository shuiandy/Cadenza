import Foundation

struct PersonProfileEvidenceDTO: Sendable {
    let profile: SpeakerProfileDTO
    let recordingCount: Int
    let recentMeetings: [PersonMeetingContextDTO]
}

struct PersonMeetingContextDTO: Sendable {
    let recordingID: UUID
    let title: String
    let date: Date
    let overview: String?
    let decisions: [String]
    let openActionItems: [String]
}
