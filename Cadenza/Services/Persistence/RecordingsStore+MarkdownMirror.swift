import Foundation
import SwiftData

extension RecordingsStore {
    func fetchMarkdownMirrorRecords(recordingIDs: Set<UUID>? = nil) -> [MarkdownMirrorRecordDTO] {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate == nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        let ledgers = (try? modelContext.fetch(FetchDescriptor<ExternalRecordingImport>())) ?? []
        var ledgerByRecordingID: [UUID: ExternalRecordingImport] = [:]
        for ledger in ledgers.sorted(by: { $0.externalKey < $1.externalKey }) {
            guard let recordingID = ledger.recording?.id,
                  ledgerByRecordingID[recordingID] == nil else { continue }
            ledgerByRecordingID[recordingID] = ledger
        }

        return recordings.compactMap { recording in
            if let recordingIDs, !recordingIDs.contains(recording.id) { return nil }
            guard let detail = fetchRecordingDetail(recordingID: recording.id) else { return nil }
            let ledger = ledgerByRecordingID[recording.id]
            return MarkdownMirrorRecordDTO(
                detail: detail,
                externalProvider: ledger?.provider,
                externalID: ledger?.externalID
            )
        }
    }
}
