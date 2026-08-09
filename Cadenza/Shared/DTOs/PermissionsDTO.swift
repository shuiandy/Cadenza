import Foundation

/// Permission status snapshot from Core → UI.
struct PermissionsDTO: Codable, Sendable {
    var hasMicrophonePermission: Bool
    var hasScreenRecordingPermission: Bool
    var hasCalendarPermission: Bool
}
