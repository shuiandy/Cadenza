import Foundation

/// Full transcript for recording detail view.
struct TranscriptDTO: Codable, Sendable {
    let id: UUID
    var fullText: String
    var segments: [TranscriptEntryDTO]
    var detectedLanguage: String?
    var createdAt: Date
}

struct TranscriptEntryDTO: Codable, Sendable, Identifiable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
}
