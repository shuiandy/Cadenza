import Foundation
import SwiftData

@Model
final class MeetingSummary {
    var id: UUID
    var overview: String
    var keyPoints: [String]
    var actionItems: [ActionItem]
    var decisions: [String]
    var followUps: [String]
    var yourTasks: [String] = []
    var provider: String // AIProvider rawValue
    var model: String
    var language: String
    var createdAt: Date
    var chaptersJSON: String?

    @Relationship(inverse: \Recording.summary)
    var recording: Recording?

    init(
        overview: String = "",
        keyPoints: [String] = [],
        actionItems: [ActionItem] = [],
        decisions: [String] = [],
        followUps: [String] = [],
        yourTasks: [String] = [],
        provider: AIProvider = .openai,
        model: String = "",
        language: String = "en"
    ) {
        self.id = UUID()
        self.overview = overview
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.decisions = decisions
        self.followUps = followUps
        self.yourTasks = yourTasks
        self.provider = provider.rawValue
        self.model = model
        self.language = language
        self.createdAt = Date()
    }
}

struct ActionItem: Codable, Identifiable, Sendable {
    var id: UUID
    var assignee: String?
    var task: String
    var deadline: String?
    var isCompleted: Bool
    var priority: ActionPriority
    var createdAt: Date?
    var updatedAt: Date?

    init(assignee: String? = nil, task: String, deadline: String? = nil, isCompleted: Bool = false, priority: ActionPriority = .medium, createdAt: Date? = Date(), updatedAt: Date? = Date()) {
        self.id = UUID()
        self.assignee = assignee
        self.task = task
        self.deadline = deadline
        self.isCompleted = isCompleted
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Handle decoding old data without isCompleted/priority fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
        task = try container.decode(String.self, forKey: .task)
        deadline = try container.decodeIfPresent(String.self, forKey: .deadline)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        priority = try container.decodeIfPresent(ActionPriority.self, forKey: .priority) ?? .medium
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

enum ActionPriority: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case low

    var displayName: String {
        switch self {
        case .high: String(localized: "High")
        case .medium: String(localized: "Medium")
        case .low: String(localized: "Low")
        }
    }

    var icon: String {
        switch self {
        case .high: "exclamationmark.circle.fill"
        case .medium: "minus.circle.fill"
        case .low: "arrow.down.circle.fill"
        }
    }

    var tint: String {
        switch self {
        case .high: "red"
        case .medium: "orange"
        case .low: "blue"
        }
    }
}
