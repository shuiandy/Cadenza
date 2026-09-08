import Foundation
import SwiftData

extension RecordingsStore {
    func fetchActionItemRecords() -> [ActionItemRecordDTO] {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate == nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        return recordings.flatMap { recording -> [ActionItemRecordDTO] in
            guard let summary = recording.summary else { return [] }
            return summary.actionItems.map { item in
                actionItemRecord(item, recording: recording)
            }
        }
    }

    @discardableResult
    func applyActionItemUpdate(
        recordingID: UUID,
        actionItemID: UUID,
        input: ActionItemUpdateInput
    ) -> ActionItemRecordDTO? {
        guard let recording = recording(byID: recordingID),
              let summary = recording.summary,
              let index = summary.actionItems.firstIndex(where: { $0.id == actionItemID }) else {
            return nil
        }

        let original = summary.actionItems[index]
        let originalRecordingUpdatedAt = recording.updatedAt
        var updated = original

        if let task = input.task?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !task.isEmpty else { return nil }
            updated.task = task
        }
        switch input.assignee {
        case .unchanged:
            break
        case .set(let value):
            updated.assignee = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        switch input.deadline {
        case .unchanged:
            break
        case .set(let value):
            updated.deadline = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let priority = input.priority { updated.priority = priority }
        if let isCompleted = input.isCompleted { updated.isCompleted = isCompleted }

        guard updated.task != original.task
                || updated.assignee != original.assignee
                || updated.deadline != original.deadline
                || updated.priority != original.priority
                || updated.isCompleted != original.isCompleted else {
            return actionItemRecord(original, recording: recording)
        }

        let now = Date()
        updated.createdAt = original.createdAt ?? recording.createdAt ?? recording.startDate
        updated.updatedAt = now
        updated.userModified = true
        summary.actionItems[index] = updated
        recording.updatedAt = now

        guard save() else {
            summary.actionItems[index] = original
            recording.updatedAt = originalRecordingUpdatedAt
            modelContext.rollback()
            return nil
        }
        return actionItemRecord(updated, recording: recording)
    }

    private func actionItemRecord(_ item: ActionItem, recording: Recording) -> ActionItemRecordDTO {
        let fallbackDate = recording.createdAt ?? recording.startDate
        return ActionItemRecordDTO(
            id: item.id,
            recordingID: recording.id,
            recordingTitle: recording.title,
            recordingDate: recording.startDate,
            folderID: recording.folder?.id,
            folderName: recording.folder?.name,
            tags: recording.tags,
            assignee: item.assignee,
            task: item.task,
            rawDeadline: item.deadline,
            deadlineDate: ActionItemDeadlineParser.parse(item.deadline),
            isCompleted: item.isCompleted,
            priority: item.priority,
            createdAt: item.createdAt ?? fallbackDate,
            updatedAt: item.updatedAt ?? fallbackDate
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
