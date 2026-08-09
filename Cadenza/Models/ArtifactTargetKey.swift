import Foundation

/// 稳定 occurrence key 构造(纯函数,无 SwiftData 依赖)。
/// occurrenceAnchor 用整数秒锚定周期实例;非周期传 nil → 空段。
/// 绝不把可变 current start 或 detached/per-instance id 塞进 key。
enum ArtifactTargetKey {
    static func make(source: String, calendarID: String,
                     providerEventID: String, occurrenceAnchor: Date?) -> String {
        let anchor = occurrenceAnchor.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return "\(source)|\(calendarID)|\(providerEventID)|\(anchor)"
    }

    static func slotKey(kind: String, targetType: String, targetKey: String) -> String {
        "\(kind)|\(targetType)|\(targetKey)"
    }
}
