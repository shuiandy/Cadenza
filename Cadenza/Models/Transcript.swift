import Foundation
import SwiftData

@Model
final class Transcript {
    var id: UUID
    var fullText: String
    var segments: [TranscriptEntry]
    var detectedLanguage: String?
    var createdAt: Date

    @Relationship(inverse: \Recording.transcript)
    var recording: Recording?

    init(fullText: String = "", segments: [TranscriptEntry] = []) {
        self.id = UUID()
        self.fullText = fullText
        self.segments = segments
        self.createdAt = Date()
    }
}

struct TranscriptEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String? = nil) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}
