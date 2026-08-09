import CryptoKit
import Foundation

enum WebSyncPayloadBuilder {
    static func build(
        snapshot: WebSyncSnapshot,
        audioSourceState: WebSyncAudioSourceState
    ) throws -> BuiltWebSyncPayload {
        try Task.checkCancellation()
        let detail = snapshot.detail
        let transcript = detail.transcript.map { value in
            WebSyncTranscript(
                version: 1,
                fullText: value.fullText,
                detectedLanguage: value.detectedLanguage ?? detail.language,
                segments: value.segments.map { segment in
                    let startMs = max(0, milliseconds(segment.startTime))
                    return WebSyncTranscriptSegment(
                        id: segment.id.uuidString.lowercased(),
                        startMs: startMs,
                        endMs: max(startMs, milliseconds(segment.endTime)),
                        text: segment.text,
                        speaker: segment.speaker ?? ""
                    )
                }
            )
        }
        // The markdown stays: it is what a reader without the structure needs,
        // and dropping it would break every client that predates `structured`.
        let summary = detail.summary.map {
            WebSyncSummary(
                format: "markdown",
                markdown: summaryMarkdown($0),
                structured: structuredSummary($0)
            )
        }
        let tags = Array(Set(detail.tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()

        func makePayload(hash: String) -> WebSyncPayload {
            WebSyncPayload(
                protocolVersion: 1,
                contentHash: hash,
                title: detail.title,
                createdAtLocal: Int64(detail.startDate.timeIntervalSince1970.rounded()),
                durationMs: milliseconds(detail.duration),
                folder: snapshot.folderPath,
                tags: tags,
                trashedAt: snapshot.trashedDate.map { Int64($0.timeIntervalSince1970.rounded()) },
                audioSourceState: audioSourceState,
                transcript: transcript,
                summary: summary,
                calendarEvent: snapshot.calendarEvent
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Task.checkCancellation()
        let hashInput = try encoder.encode(makePayload(hash: ""))
        let hash = SHA256.hash(data: hashInput).map { String(format: "%02x", $0) }.joined()
        let payload = makePayload(hash: hash)
        try Task.checkCancellation()
        return BuiltWebSyncPayload(
            encodedData: try encoder.encode(payload),
            contentHash: hash
        )
    }

    /// Carries `SummaryDTO`'s own shape across, so the web does not have to
    /// recover it by parsing `summaryMarkdown`'s output.
    ///
    /// `provider` and `model` are left behind: they describe how the summary was
    /// produced, which the markdown already records under "Generated With" for
    /// anyone who wants it, and which no reader displays as structure.
    private static func structuredSummary(_ summary: SummaryDTO) -> WebSyncStructuredSummary {
        WebSyncStructuredSummary(
            overview: summary.overview,
            keyPoints: summary.keyPoints,
            decisions: summary.decisions,
            actionItems: summary.actionItems.map { item in
                WebSyncActionItem(
                    id: item.id.uuidString.lowercased(),
                    task: item.task,
                    assignee: item.assignee ?? "",
                    deadline: item.deadline ?? "",
                    completed: item.isCompleted,
                    priority: item.priority
                )
            },
            yourTasks: summary.yourTasks,
            followUps: summary.followUps,
            chapters: summary.chapters.map {
                WebSyncChapter(title: $0.title, startSeconds: $0.startSeconds, summary: $0.summary)
            },
            language: summary.language
        )
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        Int64((seconds * 1_000).rounded())
    }

    private static func summaryMarkdown(_ summary: SummaryDTO) -> String {
        var sections: [String] = []
        if !summary.overview.isEmpty { sections.append("## Overview\n\n\(summary.overview)") }
        if !summary.keyPoints.isEmpty {
            sections.append("## Key Points\n\n" + summary.keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.decisions.isEmpty {
            sections.append("## Decisions\n\n" + summary.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.actionItems.isEmpty {
            let items = summary.actionItems.map { item in
                let owner = item.assignee.map { " (\($0))" } ?? ""
                let deadline = item.deadline.map { " — due \($0)" } ?? ""
                let priority = item.priority.isEmpty ? "" : " — priority \(item.priority)"
                return "- [\(item.isCompleted ? "x" : " ")] \(item.task)\(owner)\(deadline)\(priority)"
            }
            sections.append("## Action Items\n\n" + items.joined(separator: "\n"))
        }
        if !summary.yourTasks.isEmpty {
            sections.append("## Your Tasks\n\n" + summary.yourTasks.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.followUps.isEmpty {
            sections.append("## Follow-ups\n\n" + summary.followUps.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.chapters.isEmpty {
            let chapters = summary.chapters.map { chapter in
                let seconds = max(0, Int(chapter.startSeconds.rounded()))
                let timestamp = String(format: "%d:%02d", seconds / 60, seconds % 60)
                return "### \(chapter.title) (\(timestamp))\n\n\(chapter.summary)"
            }
            sections.append("## Chapters\n\n" + chapters.joined(separator: "\n\n"))
        }
        var provenance: [String] = []
        if !summary.provider.isEmpty { provenance.append("- Provider: \(summary.provider)") }
        if !summary.model.isEmpty { provenance.append("- Model: \(summary.model)") }
        if !summary.language.isEmpty { provenance.append("- Language: \(summary.language)") }
        if !provenance.isEmpty {
            sections.append("## Generated With\n\n" + provenance.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}
