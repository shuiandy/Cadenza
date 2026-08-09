import Foundation

struct ActionItemRecordDTO: Sendable, Identifiable {
    let id: UUID
    let recordingID: UUID
    let recordingTitle: String
    let recordingDate: Date
    let folderID: UUID?
    let folderName: String?
    let tags: [String]
    let assignee: String?
    let task: String
    let rawDeadline: String?
    let deadlineDate: Date?
    let isCompleted: Bool
    let priority: ActionPriority
    let createdAt: Date
    let updatedAt: Date
}

struct ActionItemUpdateInput: Sendable {
    enum OptionalText: Sendable {
        case unchanged
        case set(String?)
    }

    var task: String?
    var assignee: OptionalText
    var deadline: OptionalText
    var priority: ActionPriority?
    var isCompleted: Bool?

    init(
        task: String? = nil,
        assignee: OptionalText = .unchanged,
        deadline: OptionalText = .unchanged,
        priority: ActionPriority? = nil,
        isCompleted: Bool? = nil
    ) {
        self.task = task
        self.assignee = assignee
        self.deadline = deadline
        self.priority = priority
        self.isCompleted = isCompleted
    }
}

enum ActionItemDeadlineParser {
    static func parse(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = try? Date(raw, strategy: .iso8601) {
            return date
        }
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MMM d, yyyy", "MMMM d, yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
