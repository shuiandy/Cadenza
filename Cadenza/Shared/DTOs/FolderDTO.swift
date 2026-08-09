import Foundation

/// Folder for UI display (mirrors Folder @Model without SwiftData dependency).
struct FolderDTO: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var iconColor: String
    var colorHex: String?
    var status: String
    var createdAt: Date
    var sortOrder: Int
    var recordingCount: Int
    var parentFolderID: UUID?
    var subfolderCount: Int
}
