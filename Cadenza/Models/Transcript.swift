import Foundation
import SwiftData

@Model
final class Transcript {
    var id: UUID
    var fullText: String
    var segments: [TranscriptEntry]
    var detectedLanguage: String?
    var createdAt: Date
    /// Compact provenance computed when immutable transcript content is saved.
    var summarySourceVersionJSON: String? = nil

    @Relationship(inverse: \Recording.transcript)
    var recording: Recording?

    init(fullText: String = "", segments: [TranscriptEntry] = []) {
        self.id = UUID()
        self.fullText = fullText
        self.segments = segments
        self.createdAt = Date()
    }
    func captureSummarySource() {
        let dto = TranscriptDTO(id: id, fullText: fullText,
            segments: segments.map { TranscriptEntryDTO(id: $0.id, startTime: $0.startTime,
                endTime: $0.endTime, text: $0.text, speaker: $0.speaker) },
            detectedLanguage: detectedLanguage, createdAt: createdAt)
        summarySourceVersionJSON = (try? JSONEncoder().encode(SummarySourceVersion.capture(dto, mappings: [])))
            .map { String(decoding: $0, as: UTF8.self) }
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
