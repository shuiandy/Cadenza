import Foundation
import SwiftData

extension RecordingsStore {
    func fetchPersonProfileEvidence(maxMeetingsPerPerson: Int = 10) -> [PersonProfileEvidenceDTO] {
        let profiles = (try? modelContext.fetch(FetchDescriptor<SpeakerProfile>())) ?? []
        let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate == nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        ))) ?? []

        return profiles.map { profile in
            let matching = recordings.filter { recording in
                (recording.speakerMappings ?? []).contains { $0.profileID == profile.id }
            }
            return PersonProfileEvidenceDTO(
                profile: speakerProfileToDTO(profile),
                recordingCount: matching.count,
                recentMeetings: matching.prefix(maxMeetingsPerPerson).map(personMeetingContext)
            )
        }
    }

    func fetchPersonMeetingContext(profileID: UUID, limit: Int = 20) -> [PersonMeetingContextDTO]? {
        guard speakerProfile(byID: profileID) != nil else { return nil }
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate == nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        return recordings.filter { recording in
            (recording.speakerMappings ?? []).contains { $0.profileID == profileID }
        }.prefix(limit).map(personMeetingContext)
    }

    private func personMeetingContext(_ recording: Recording) -> PersonMeetingContextDTO {
        PersonMeetingContextDTO(
            recordingID: recording.id,
            title: recording.title,
            date: recording.startDate,
            overview: recording.summary?.overview,
            decisions: recording.summary?.decisions ?? [],
            openActionItems: recording.summary?.actionItems.filter { !$0.isCompleted }.map(\.task) ?? []
        )
    }
}
