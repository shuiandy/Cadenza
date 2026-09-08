import Foundation
import CryptoKit

struct SummaryContextInput: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var focus = ""
    var background = ""
    var includeCalendar = false
    var includeHistory = false
    var historyIDs: [UUID] = []
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    static func decode(_ text: String?) -> Self {
        guard let text, let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)), value.schemaVersion == 1 else { return Self() }
        return value
    }
}

struct SummaryContextSnapshot: Codable, Sendable {
    struct Fact: Codable, Sendable {
        let id: String
        let text: String
    }
    struct History: Codable, Sendable {
        let recordingID: UUID
        let date: Date
        let summaryID: UUID
        let digest: String
        let facts: [Fact]
        var title: String? = nil
    }
    let summaryID: UUID
    let summaryDigest: String
    let userName: String
    let jobTitle: String
    let focus: String
    let background: String
    let calendar: String?
    let calendarID: String?
    let history: [History]
    let facts: [Fact]
    let inputJSON: String

    var fingerprint: String { Self.digest(self) }
    // References exist only within this request. Local UUIDs and fingerprints
    // remain in the persisted snapshot and never enter the provider payload.
    func providerData() throws -> Data {
        struct Prior: Encodable { let reference: String; let date: Date; let title: String?; let facts: [Fact] }
        struct Input: Encodable {
            let userName: String; let jobTitle: String; let focus: String; let background: String
            let calendar: String?; let history: [Prior]; let facts: [Fact]
        }
        func aliases(_ facts: [Fact]) -> [Fact] {
            facts.enumerated().map { Fact(id: "f\($0.offset)", text: $0.element.text) }
        }
        return try JSONEncoder().encode(Input(userName: String(userName.prefix(200)),
            jobTitle: String(jobTitle.prefix(500)), focus: focus, background: background,
            calendar: calendar, history: history.enumerated().map {
                Prior(reference: "h\($0.offset)", date: $0.element.date, title: $0.element.title, facts: aliases($0.element.facts))
            }, facts: aliases(facts)))
    }

    func resolveProviderReferences(_ text: String) -> String? {
        guard let data = SummaryPrompt.responseJSON(text).data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func references(_ aliases: [String], facts: [Fact]) -> [String]? {
            let lookup = Dictionary(uniqueKeysWithValues: facts.enumerated().map { ("f\($0.offset)", $0.element.id) })
            let result = aliases.compactMap { lookup[$0] }
            return result.count == aliases.count ? result : nil
        }
        for key in ["relevant", "suggestions"] {
            if object[key] == nil { continue }
            guard var items = object[key] as? [[String: Any]] else { return nil }
            for i in items.indices {
                guard let ids = items[i]["references"] as? [String], let local = references(ids, facts: facts) else { return nil }
                items[i]["references"] = local
            }
            object[key] = items
        }
        if object["progress"] != nil {
            guard var items = object["progress"] as? [[String: Any]] else { return nil }
            let historyLookup = Dictionary(uniqueKeysWithValues: history.enumerated().map { ("h\($0.offset)", $0.element) })
            for i in items.indices {
                guard let alias = items[i]["recordingID"] as? String, let prior = historyLookup[alias],
                      let previous = items[i]["previousReference"] as? String,
                      let resolved = references([previous], facts: prior.facts)?.first,
                      let current = items[i]["currentReferences"] as? [String],
                      let resolvedCurrent = references(current, facts: facts) else { return nil }
                items[i]["recordingID"] = prior.recordingID.uuidString
                items[i]["previousReference"] = resolved
                items[i]["currentReferences"] = resolvedCurrent
            }
            object["progress"] = items
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }
    private static func calendarNotes(_ text: String) -> String {
        String(text.replacingOccurrences(of: #"https?://[^\s]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "", options: [.regularExpression, .caseInsensitive]).prefix(4000))
    }
    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func facts(_ summary: SummaryDTO) -> [Fact] {
        [Fact(id: "overview", text: summary.overview)]
        + summary.keyPoints.enumerated().map { Fact(id: "key_points/\($0.offset)", text: $0.element) }
        + summary.decisions.enumerated().map { Fact(id: "decisions/\($0.offset)", text: $0.element) }
        + summary.followUps.enumerated().map { Fact(id: "follow_ups/\($0.offset)", text: $0.element) }
        + summary.actionItems.map { Fact(id: "action_items/\($0.id)", text: "\($0.assignee ?? "?"): \($0.task); deadline=\($0.deadline ?? "?"); completed=\($0.isCompleted)") }
    }
    static func build(detail: RecordingDetailDTO, input: SummaryContextInput, userName: String,
                      jobTitle: String, defaultFocus: String, event: MeetingEventDTO?, history: [RecordingDetailDTO]) -> Self? {
        guard let summary = detail.summary, summary.generationMetadata?.sourceChanged != true else { return nil }
        let validEvent = input.includeCalendar && event?.id == detail.linkedCalendarEventID ? event : nil
        // Explicitly selected history only; these guards also protect injected/test callers.
        let selected = Set(input.historyIDs)
        let earliest = detail.startDate.addingTimeInterval(-90 * 86400)
        let allowedHistory = input.includeHistory ? Array(history.filter {
            $0.id != detail.id && selected.contains($0.id) && $0.startDate < detail.startDate && $0.startDate >= earliest
                && $0.summary != nil && $0.summary?.generationMetadata?.sourceChanged != true
        }.sorted { $0.startDate == $1.startDate ? $0.id.uuidString < $1.id.uuidString : $0.startDate > $1.startDate }.prefix(3)) : []
        let historySnapshots = allowedHistory.compactMap { old -> History? in
            guard let summary = old.summary else { return nil }
            return History(recordingID: old.id, date: old.startDate, summaryID: summary.id,
                digest: digest(summary), facts: facts(summary), title: old.title)
        }
        let calendarText = validEvent.map {
            "Calendar background only (not evidence of discussion): \(calendarNotes($0.title))\nStart: \($0.startDate.ISO8601Format())\nNotes: \(calendarNotes($0.notes ?? ""))\nAttendees: \($0.attendees.map(\.name).filter { !$0.contains("@") }.sorted().joined(separator: ", "))"
        }
        return Self(summaryID: summary.id, summaryDigest: digest(summary), userName: userName,
            jobTitle: jobTitle, focus: String((input.focus.isEmpty ? defaultFocus : input.focus).prefix(2000)),
            background: String(input.background.prefix(4000)), calendar: calendarText, calendarID: validEvent?.id,
            history: historySnapshots, facts: facts(summary), inputJSON: input.json)
    }
}

struct PersonalRelevance: Codable, Sendable {
    struct Item: Codable, Sendable, Identifiable {
        var id: String { references.joined(separator: "/") + text }
        let text: String
        let references: [String]
    }
    struct Progress: Codable, Sendable, Identifiable {
        var id: String { recordingID.uuidString + previousReference }
        let recordingID: UUID
        let previousReference: String
        let currentReferences: [String]
        let text: String
    }
    var schemaVersion = 1
    let summaryID: UUID
    let contextFingerprint: String
    let source: SummaryContextSnapshot
    let relevant: [Item]
    let suggestions: [Item]
    let progress: [Progress]
    let createdAt: Date

    static func parse(_ text: String, snapshot: SummaryContextSnapshot) -> Self? {
        struct Response: Decodable {
            let relevant: [Item]; let suggestions: [Item]; let progress: [Progress]
            enum CodingKeys: String, CodingKey { case relevant, suggestions, progress }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                relevant = try c.decodeIfPresent([Item].self, forKey: .relevant) ?? []
                suggestions = try c.decodeIfPresent([Item].self, forKey: .suggestions) ?? []
                progress = try c.decodeIfPresent([Progress].self, forKey: .progress) ?? []
            }
        }
        guard let data = SummaryPrompt.responseJSON(text).data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let currentIDs = Set(snapshot.facts.map(\.id))
        func valid(_ item: Item) -> Bool { !item.text.isEmpty && !item.references.isEmpty && Set(item.references).isSubset(of: currentIDs) }
        guard response.relevant.count <= 8, response.suggestions.count <= 5, response.progress.count <= 5,
              response.relevant.allSatisfy(valid), response.suggestions.allSatisfy(valid),
              response.progress.allSatisfy({ item in
                  guard let prior = snapshot.history.first(where: { $0.recordingID == item.recordingID }) else { return false }
                  return prior.facts.contains(where: { $0.id == item.previousReference }) && Set(item.currentReferences).isSubset(of: currentIDs)
              }) else { return nil }
        return Self(summaryID: snapshot.summaryID, contextFingerprint: snapshot.fingerprint, source: snapshot,
            relevant: response.relevant, suggestions: response.suggestions, progress: response.progress, createdAt: Date())
    }
}
