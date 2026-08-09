import Foundation

enum RecordingState: Sendable {
    case idle
    case recording
    case paused
    case transcribing
    case summarizing
}
