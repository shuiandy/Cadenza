import Foundation

/// Live transcript segment (mirrors TranscriptSegment without Observable).
struct TranscriptSegmentDTO: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: TimeInterval
    let text: String
    let isFinal: Bool
    let speaker: String?

    init(id: UUID = UUID(), timestamp: TimeInterval, text: String, isFinal: Bool, speaker: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
    }

    /// Formats timestamp as "m:ss" for compact display.
    var formattedTimestamp: String {
        let minutes = Int(timestamp) / 60
        let seconds = Int(timestamp) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
