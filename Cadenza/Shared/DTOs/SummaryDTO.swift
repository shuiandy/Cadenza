import Foundation

/// Meeting summary for recording detail view.
struct SummaryDTO: Codable, Sendable {
    let id: UUID
    var overview: String
    var keyPoints: [String]
    var actionItems: [ActionItemDTO]
    var decisions: [String]
    var followUps: [String]
    var yourTasks: [String]
    var provider: String
    var model: String
    var language: String
    var createdAt: Date
    var chapters: [ChapterDTO]
}

struct ActionItemDTO: Codable, Sendable, Identifiable {
    let id: UUID
    var assignee: String?
    var task: String
    var deadline: String?
    var isCompleted: Bool
    var priority: String // ActionPriority rawValue
    var createdAt: Date? = nil
    var updatedAt: Date? = nil
}

struct ChapterDTO: Codable, Sendable {
    var title: String
    var startSeconds: TimeInterval
    var summary: String
}
