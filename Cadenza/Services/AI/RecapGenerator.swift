import Foundation

/// Generates weekly and monthly recap summaries from aggregated recording data.
@MainActor
final class RecapGenerator {
    private let store: RecordingsStore
    private let apiKeyResolver: (AIProvider) -> String?
    private let defaults = UserDefaults.standard

    init(store: RecordingsStore, apiKeyResolver: @escaping (AIProvider) -> String? = { KeychainManager.shared.apiKey(for: $0) }) {
        self.store = store
        self.apiKeyResolver = apiKeyResolver
    }

    // MARK: - Startup Check

    /// Check and generate any missing recaps. Called at app startup.
    func generateMissingRecaps() async {
        let calendar = Calendar.current
        let now = Date()

        // Weekly: check if last week's recap exists
        if let lastMonday = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) {
            let previousMonday = calendar.date(byAdding: .weekOfYear, value: -1, to: lastMonday)!
            let previousSunday = calendar.date(byAdding: .day, value: 7, to: previousMonday)!

            if await !store.recapExists(period: "weekly", startDate: previousMonday) {
                let recordings = await store.fetchRecordingsForRecap(from: previousMonday, to: previousSunday)
                if !recordings.isEmpty {
                    NSLog("[RecapGenerator] generating weekly recap for %@ – %@", previousMonday.description, previousSunday.description)
                    await generateWeeklyRecap(startDate: previousMonday, endDate: previousSunday, recordings: recordings)
                }
            }
        }

        // Monthly: check if last month's recap exists
        let firstOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let firstOfLastMonth = calendar.date(byAdding: .month, value: -1, to: firstOfThisMonth)!

        if await !store.recapExists(period: "monthly", startDate: firstOfLastMonth) {
            let weeklyRecaps = await store.fetchRecaps(period: "weekly").filter {
                $0.startDate >= firstOfLastMonth && $0.startDate < firstOfThisMonth
            }
            if !weeklyRecaps.isEmpty {
                NSLog("[RecapGenerator] generating monthly recap for %@", firstOfLastMonth.description)
                await generateMonthlyRecap(startDate: firstOfLastMonth, endDate: firstOfThisMonth, weeklyRecaps: weeklyRecaps)
            }
        }
    }

    // MARK: - Weekly Recap

    private func generateWeeklyRecap(
        startDate: Date,
        endDate: Date,
        recordings: [(id: UUID, title: String, date: Date, duration: TimeInterval, tags: [String], overview: String, keyPoints: [String], decisions: [String], actionItems: [ActionItemResult])]
    ) async {
        guard let (service, modelID) = resolveService() else {
            NSLog("[RecapGenerator] no AI service available")
            return
        }

        // Compute stats
        let allActionItems = recordings.flatMap { $0.actionItems.map(\.task) }
        let allDecisions = recordings.flatMap(\.decisions)
        let stats = RecapStats(
            meetingCount: recordings.count,
            totalDuration: recordings.reduce(0) { $0 + $1.duration },
            actionItemCount: allActionItems.count,
            decisionCount: allDecisions.count
        )

        // Build prompt input
        let input = recordings.map { rec in
            var parts = ["### \(rec.title) — \(Self.formatDate(rec.date)) [\(rec.tags.joined(separator: ", "))]"]
            if !rec.overview.isEmpty { parts.append("Overview: \(rec.overview)") }
            if !rec.keyPoints.isEmpty { parts.append("Key Points:\n" + rec.keyPoints.map { "- \($0)" }.joined(separator: "\n")) }
            if !rec.decisions.isEmpty { parts.append("Decisions:\n" + rec.decisions.map { "- \($0)" }.joined(separator: "\n")) }
            if !rec.actionItems.isEmpty { parts.append("Action Items:\n" + rec.actionItems.map { "- \($0.task)" }.joined(separator: "\n")) }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")

        let title = Self.weeklyTitle(startDate: startDate, endDate: endDate)

        let systemPrompt = """
        You are a meeting recap assistant. Given summaries of multiple meetings from one week, produce a consolidated weekly recap.

        Respond with valid JSON only:
        {
          "overview": "2-3 sentence summary of the week's key themes and outcomes",
          "sections": [
            {
              "category": "Meeting type or group name (e.g. '1-on-1 with Manager', 'Standups', 'Design Reviews')",
              "summary": "What happened across these meetings this week",
              "recordingTitles": ["exact titles of meetings in this group"]
            }
          ]
        }

        Rules:
        - Group meetings by type/topic similarity. Use descriptive category names.
        - Do NOT invent information. Only summarize what's in the input.
        - If there's only one meeting of a type, still create a section for it.
        - Output language should match the input language.
        """

        do {
            let fullResponse = try await AIGenerationGate.shared.run { () async throws -> String in
                var fullResponse = ""
                let stream = service.streamChat(systemPrompt: systemPrompt, userMessage: input, model: modelID)
                for try await chunk in stream {
                    fullResponse += chunk
                }
                return fullResponse
            }

            // Parse response
            let parsed = parseRecapResponse(fullResponse, recordings: recordings)

            let recap = Recap(
                period: "weekly",
                startDate: startDate,
                endDate: endDate,
                title: title,
                overview: parsed.overview,
                sections: parsed.sections,
                stats: stats,
                recordingIDs: recordings.map(\.id),
                allActionItems: allActionItems,
                allDecisions: allDecisions,
                provider: service.provider.rawValue
            )
            await store.saveRecap(recap)
            NSLog("[RecapGenerator] weekly recap saved: %d recordings, %d sections", recordings.count, parsed.sections.count)
        } catch {
            NSLog("[RecapGenerator] weekly recap generation failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Monthly Recap

    private func generateMonthlyRecap(
        startDate: Date,
        endDate: Date,
        weeklyRecaps: [RecapDTO]
    ) async {
        guard let (service, modelID) = resolveService() else { return }

        // Aggregate stats
        let stats = RecapStats(
            meetingCount: weeklyRecaps.reduce(0) { $0 + $1.stats.meetingCount },
            totalDuration: weeklyRecaps.reduce(0) { $0 + $1.stats.totalDuration },
            actionItemCount: weeklyRecaps.reduce(0) { $0 + $1.stats.actionItemCount },
            decisionCount: weeklyRecaps.reduce(0) { $0 + $1.stats.decisionCount }
        )

        let allActionItems = weeklyRecaps.flatMap(\.allActionItems)
        let allDecisions = weeklyRecaps.flatMap(\.allDecisions)
        let allRecordingIDs = weeklyRecaps.flatMap(\.recordingIDs)

        let input = weeklyRecaps.map { recap in
            var parts = ["### \(recap.title)"]
            parts.append("Overview: \(recap.overview)")
            for section in recap.sections {
                parts.append("- \(section.category): \(section.summary)")
            }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")

        let title = Self.monthlyTitle(startDate: startDate)

        let systemPrompt = """
        You are a meeting recap assistant. Given weekly recap summaries for a month, produce a consolidated monthly recap.

        Respond with valid JSON only:
        {
          "overview": "3-4 sentence summary of the month's key themes, progress, and outcomes",
          "sections": [
            {
              "category": "Theme or meeting type",
              "summary": "Month-level summary for this category",
              "recordingTitles": []
            }
          ]
        }

        Rules:
        - Identify recurring themes and track progress across weeks.
        - Highlight key decisions and milestones.
        - Do NOT invent information.
        - Output language should match the input language.
        """

        do {
            let fullResponse = try await AIGenerationGate.shared.run { () async throws -> String in
                var fullResponse = ""
                let stream = service.streamChat(systemPrompt: systemPrompt, userMessage: input, model: modelID)
                for try await chunk in stream {
                    fullResponse += chunk
                }
                return fullResponse
            }

            let parsed = parseRecapResponse(fullResponse, recordings: [])

            let recap = Recap(
                period: "monthly",
                startDate: startDate,
                endDate: endDate,
                title: title,
                overview: parsed.overview,
                sections: parsed.sections,
                stats: stats,
                recordingIDs: allRecordingIDs,
                allActionItems: allActionItems,
                allDecisions: allDecisions,
                provider: service.provider.rawValue
            )
            await store.saveRecap(recap)
            NSLog("[RecapGenerator] monthly recap saved: %d weeks", weeklyRecaps.count)
        } catch {
            NSLog("[RecapGenerator] monthly recap generation failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func resolveService() -> (AIServiceProtocol, String)? {
        let providerRaw = defaults.string(forKey: "defaultAIProvider") ?? AIProvider.apple.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? .apple
        let apiKey: String
        if provider.requiresAPIKey {
            guard let key = apiKeyResolver(provider), !key.isEmpty else { return nil }
            apiKey = key
        } else {
            apiKey = ""
        }
        let model = provider.summaryModel
        guard let service = provider.makeChatService(apiKey: apiKey) else { return nil }
        return (service, model)
    }

    private struct ParsedRecap {
        let overview: String
        let sections: [RecapSection]
    }

    private func parseRecapResponse(
        _ response: String,
        recordings: [(id: UUID, title: String, date: Date, duration: TimeInterval, tags: [String], overview: String, keyPoints: [String], decisions: [String], actionItems: [ActionItemResult])]
    ) -> ParsedRecap {
        // Extract JSON from response (may be wrapped in markdown code fence)
        let jsonString = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[RecapGenerator] failed to parse JSON response")
            return ParsedRecap(overview: response.prefix(500).description, sections: [])
        }

        let overview = json["overview"] as? String ?? ""
        let sectionsJSON = json["sections"] as? [[String: Any]] ?? []

        let sections = sectionsJSON.map { section -> RecapSection in
            let category = section["category"] as? String ?? String(localized: "General")
            let summary = section["summary"] as? String ?? ""
            let titles = section["recordingTitles"] as? [String] ?? []
            // Match recording titles to IDs
            let matchedIDs = titles.compactMap { title in
                recordings.first(where: { $0.title.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains($0.title) })?.id
            }
            return RecapSection(category: category, summary: summary, recordingIDs: matchedIDs)
        }

        return ParsedRecap(overview: overview, sections: sections)
    }

    static func weeklyTitle(
        startDate: Date,
        endDate: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let start = formatShortDate(startDate, locale: locale, calendar: calendar, timeZone: timeZone)
        let inclusiveEnd = endDate.addingTimeInterval(-1)
        let end = formatShortDate(inclusiveEnd, locale: locale, calendar: calendar, timeZone: timeZone)
        return LocalizedBundle.string("Weekly Recap: \(start) – \(end)", locale: locale)
    }

    static func monthlyTitle(
        startDate: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        let month = formatter.string(from: startDate)
        return LocalizedBundle.string("Monthly Recap: \(month)", locale: locale)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter.string(from: date)
    }

    private static func formatShortDate(
        _ date: Date,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}
