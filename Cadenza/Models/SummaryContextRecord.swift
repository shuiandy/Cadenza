import Foundation
import SwiftData

/// Private per-meeting settings and derived personalization, deliberately outside Recording
/// and outside SummaryDTO / sync / MCP / automatic export payloads.
@Model
final class SummaryContextRecord {
    @Attribute(.unique) var recordingID: UUID
    var inputJSON: String
    var resultJSON: String?
    init(recordingID: UUID, inputJSON: String) {
        self.recordingID = recordingID
        self.inputJSON = inputJSON
    }
}
