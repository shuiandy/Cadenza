import Foundation

struct ChatSession: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date
    var provider: String
    var model: String

    init(
        id: UUID = UUID(),
        title: String,
        messages: [ChatMessage],
        provider: String,
        model: String
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = Date()
        self.updatedAt = Date()
        self.provider = provider
        self.model = model
    }
}
