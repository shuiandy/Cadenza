import Foundation

/// A segment of live or recorded transcript text.
struct TranscriptSegment: Identifiable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    let endTime: TimeInterval?
    let text: String
    let isFinal: Bool
    let speaker: String?

    init(id: UUID = UUID(), timestamp: TimeInterval, endTime: TimeInterval? = nil, text: String, isFinal: Bool, speaker: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
    }

    init(timestamp: TimeInterval, text: String, isFinal: Bool) {
        self.init(id: UUID(), timestamp: timestamp, endTime: nil, text: text, isFinal: isFinal)
    }

    func updating(
        timestamp: TimeInterval? = nil,
        text: String? = nil,
        isFinal: Bool? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            timestamp: timestamp ?? self.timestamp,
            endTime: self.endTime,
            text: text ?? self.text,
            isFinal: isFinal ?? self.isFinal,
            speaker: self.speaker
        )
    }
}
