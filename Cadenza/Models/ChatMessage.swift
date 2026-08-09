import Foundation

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let timestamp: Date
    /// IDs of recordings explicitly @-mentioned in this message.
    var mentionedRecordingIDs: [UUID] = []
    /// Concrete recording scope resolved for this turn by the context assembler.
    /// Kept separate from explicit mentions so it can be restored without
    /// rendering inferred recordings as user-authored @mentions.
    var contextRecordingIDs: [UUID]? = nil

    init(role: ChatRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}
