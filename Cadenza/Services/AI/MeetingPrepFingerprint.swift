import Foundation
import CryptoKit

/// 事件指纹:内容变化(时间/参会人+状态/notes/URL/标题)则指纹变。纯函数。
enum MeetingPrepFingerprint {
    static func compute(_ event: MeetingEvent) -> String {
        let attendees = event.attendees
            .map { "\($0.email.lowercased()):\($0.status.rawValue)" }
            .sorted()
            .joined(separator: ",")
        let raw = [
            event.title,
            String(Int(event.startDate.timeIntervalSince1970)),
            String(Int(event.endDate.timeIntervalSince1970)),
            attendees,
            event.notes ?? "",
            event.meetingURL?.absoluteString ?? ""
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
