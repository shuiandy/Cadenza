import Foundation
import SwiftData

extension RecordingsStore {
    private func contextRecord(_ id: UUID) throws -> SummaryContextRecord? {
        var descriptor = FetchDescriptor<SummaryContextRecord>(predicate: #Predicate { $0.recordingID == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func fetchSummaryContext(recordingID: UUID) -> (SummaryContextInput, PersonalRelevance?) {
        guard let recording = recording(byID: recordingID), recording.trashedDate == nil,
              let record = try? contextRecord(recordingID) else { return (.init(), nil) }
        let input = SummaryContextInput.decode(record.inputJSON)
        let result = record.resultJSON.flatMap { try? JSONDecoder().decode(PersonalRelevance.self, from: Data($0.utf8)) }
        guard let result, result.schemaVersion == 1, record.inputJSON == result.source.inputJSON, contextSourcesAreCurrent(result.source) else { return (input, nil) }
        return (input, result)
    }

    @discardableResult
    func saveSummaryContext(recordingID: UUID, input: SummaryContextInput) -> Bool {
        guard let recording = recording(byID: recordingID), recording.trashedDate == nil else { return false }
        do {
            let record = try contextRecord(recordingID)
            let json = input.json
            if record?.inputJSON == json { return true }
            return performStandaloneMutation {
                if let record { record.inputJSON = json; record.resultJSON = nil }
                else { modelContext.insert(SummaryContextRecord(recordingID: recordingID, inputJSON: json)) }
            }
        } catch { return false }
    }

    @discardableResult
    func savePersonalRelevance(recordingID: UUID, result: PersonalRelevance) -> Bool {
        guard !Task.isCancelled, contextSourcesAreCurrent(result.source),
              let record = try? contextRecord(recordingID), record.inputJSON == result.source.inputJSON,
              let detail = fetchSummaryContextDetail(recordingID: recordingID), detail.summary?.id == result.summaryID
        else { return false }
        do {
            let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            return performStandaloneMutation { record.resultJSON = json }
        } catch { return false }
    }

    private func contextSourcesAreCurrent(_ source: SummaryContextSnapshot) -> Bool {
        // All queries use this profile's store. Never follow an ID into another store.
        let summaryID = source.summaryID
        var descriptor = FetchDescriptor<MeetingSummary>(predicate: #Predicate { $0.id == summaryID })
        descriptor.fetchLimit = 1
        guard let model = try? modelContext.fetch(descriptor).first,
              let recording = model.recording, recording.trashedDate == nil,
              let detail = fetchSummaryContextDetail(recordingID: recording.id),
              let summary = detail.summary, summary.generationMetadata?.sourceChanged != true,
              SummaryContextSnapshot.digest(summary) == source.summaryDigest,
              source.calendarID == nil || source.calendarID == detail.linkedCalendarEventID else { return false }
        for old in source.history {
            guard let record = self.recording(byID: old.recordingID), record.trashedDate == nil,
                  record.startDate < detail.startDate, record.startDate >= detail.startDate.addingTimeInterval(-90 * 86400),
                  let prior = fetchSummaryContextDetail(recordingID: old.recordingID)?.summary,
                  prior.id == old.summaryID, SummaryContextSnapshot.digest(prior) == old.digest else { return false }
        }
        return true
    }

    /// Explicit selection and fixed window shared by meeting-context consumers.
    func fetchConfirmedSummaryHistory(ids: [UUID], currentID: UUID, before: Date) -> [RecordingDetailDTO] {
        let earliest = before.addingTimeInterval(-90 * 86400)
        let records = Set(ids).compactMap { id -> Recording? in
            guard id != currentID, let record = recording(byID: id), record.trashedDate == nil,
                  record.startDate < before, record.startDate >= earliest, record.summary != nil else { return nil }
            return record
        }.sorted { $0.startDate == $1.startDate ? $0.id.uuidString < $1.id.uuidString : $0.startDate > $1.startDate }
        return records.prefix(3).compactMap { fetchSummaryContextDetail(recordingID: $0.id) }
    }

    /// Cheap invalidation for a detail panel. Unrelated library changes do not
    /// cause transcript materialization or history/candidate reloads.
    func summaryContextRevision(recordingID: UUID) -> String {
        let context = try? contextRecord(recordingID)
        let input = SummaryContextInput.decode(context?.inputJSON)
        let ids = [recordingID] + (input.includeHistory ? input.historyIDs : [])
        var parts = [context?.inputJSON ?? "", context?.resultJSON ?? ""]
        for id in ids {
            guard let r = recording(byID: id) else { parts.append("missing/\(id)"); continue }
            parts.append("\(r.id)|\(r.updatedAt?.timeIntervalSince1970 ?? 0)|\(r.trashedDate?.timeIntervalSince1970 ?? 0)|\(r.startDate)|\(r.title)|\(r.summary?.id.uuidString ?? "")|\(r.transcript?.id.uuidString ?? "")")
            parts.append(SummaryContextSnapshot.digest(speakerMappings(forRecordingID: id)))
        }
        return SummaryContextSnapshot.digest(parts)
    }
}
