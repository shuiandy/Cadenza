import Foundation
import SwiftData

@Model
final class Folder {
    var id: UUID
    var name: String
    var icon: String
    var iconColor: String = ""
    var colorHex: String?
    var status: String = "active"
    var createdAt: Date
    var sortOrder: Int

    @Relationship(deleteRule: .nullify, inverse: \Recording.folder)
    var recordings: [Recording]

    @Relationship(deleteRule: .nullify)
    var parentFolder: Folder?

    @Relationship(deleteRule: .nullify, inverse: \Folder.parentFolder)
    var subfolders: [Folder]

    init(name: String = "New Folder", icon: String = "folder", iconColor: String = "", colorHex: String? = nil, status: String = "active", sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.iconColor = iconColor
        self.colorHex = colorHex
        self.status = status
        self.createdAt = Date()
        self.sortOrder = sortOrder
        self.recordings = []
        self.subfolders = []
    }
}
