import Foundation

struct MarkdownMirrorRecordDTO: Sendable {
    let detail: RecordingDetailDTO
    let externalProvider: String?
    let externalID: String?
}
