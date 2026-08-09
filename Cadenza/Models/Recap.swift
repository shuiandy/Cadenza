import Foundation
import SwiftData

@Model
final class Recap {
    var id: UUID
    var period: String  // "weekly" | "monthly"
    var startDate: Date
    var endDate: Date
    var title: String
    var overview: String
    var sectionsJSON: Data
    var statsJSON: Data
    var recordingIDs: [UUID]
    var allActionItems: [String]
    var allDecisions: [String]
    var provider: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        period: String,
        startDate: Date,
        endDate: Date,
        title: String,
        overview: String = "",
        sections: [RecapSection] = [],
        stats: RecapStats = RecapStats(),
        recordingIDs: [UUID] = [],
        allActionItems: [String] = [],
        allDecisions: [String] = [],
        provider: String = ""
    ) {
        self.id = id
        self.period = period
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.overview = overview
        self.sectionsJSON = (try? JSONEncoder().encode(sections)) ?? Data()
        self.statsJSON = (try? JSONEncoder().encode(stats)) ?? Data()
        self.recordingIDs = recordingIDs
        self.allActionItems = allActionItems
        self.allDecisions = allDecisions
        self.provider = provider
        self.createdAt = Date()
    }

    var sections: [RecapSection] {
        get { (try? JSONDecoder().decode([RecapSection].self, from: sectionsJSON)) ?? [] }
        set { sectionsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var stats: RecapStats {
        get { (try? JSONDecoder().decode(RecapStats.self, from: statsJSON)) ?? RecapStats() }
        set { statsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

// MARK: - Supporting Types

struct RecapSection: Codable, Identifiable, Sendable {
    let id: UUID
    let category: String
    let summary: String
    let recordingIDs: [UUID]

    init(id: UUID = UUID(), category: String, summary: String, recordingIDs: [UUID] = []) {
        self.id = id
        self.category = category
        self.summary = summary
        self.recordingIDs = recordingIDs
    }
}

struct RecapStats: Codable, Sendable {
    var meetingCount: Int
    var totalDuration: TimeInterval
    var actionItemCount: Int
    var decisionCount: Int

    init(meetingCount: Int = 0, totalDuration: TimeInterval = 0, actionItemCount: Int = 0, decisionCount: Int = 0) {
        self.meetingCount = meetingCount
        self.totalDuration = totalDuration
        self.actionItemCount = actionItemCount
        self.decisionCount = decisionCount
    }
}

// MARK: - DTO

struct RecapDTO: Identifiable, Sendable {
    let id: UUID
    let period: String
    let startDate: Date
    let endDate: Date
    let title: String
    let overview: String
    let sections: [RecapSection]
    let stats: RecapStats
    let recordingIDs: [UUID]
    let allActionItems: [String]
    let allDecisions: [String]

    init(from recap: Recap) {
        self.id = recap.id
        self.period = recap.period
        self.startDate = recap.startDate
        self.endDate = recap.endDate
        self.title = recap.title
        self.overview = recap.overview
        self.sections = recap.sections
        self.stats = recap.stats
        self.recordingIDs = recap.recordingIDs
        self.allActionItems = recap.allActionItems
        self.allDecisions = recap.allDecisions
    }
}
