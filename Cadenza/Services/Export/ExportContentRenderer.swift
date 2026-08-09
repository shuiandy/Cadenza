import Foundation

/// Metadata sidecar written next to exported recording files.
struct ExportMetadata: Codable, Sendable {
    let id: UUID
    let title: String
    let startDate: Date
    let endDate: Date?
    let duration: TimeInterval
    let language: String
    let detectedLanguage: String?
    let tags: [String]
    let folderPath: [String]
    let meetingApp: String?
    let source: String?
    let speakers: [String]
    let hasTranscript: Bool
    let hasSummary: Bool
    let exportedAt: Date
}

/// Pure renderers turning recording DTOs into exportable file contents.
/// No AppKit; deterministic given inputs (metadata determinism requires a fixed `exportedAt`).
enum ExportContentRenderer {

    // MARK: - Speaker resolution

    /// Mapping wins; otherwise the friendly formatter ("Speaker N").
    /// UI-only "可能是 X" suggestions deliberately do not leak into exported files.
    static func speakerDisplayName(rawLabel: String, mappings: [SpeakerLabelMappingDTO]) -> String {
        if let mapping = mappings.first(where: { $0.rawLabel == rawLabel }) {
            return mapping.profileName
        }
        return SpeakerLabelFormatter.displayName(forRawLabel: rawLabel)
    }

    // MARK: - Transcript

    /// Plain text: one line per entry, "[m:ss] Speaker: text".
    static func transcriptText(_ transcript: TranscriptDTO, mappings: [SpeakerLabelMappingDTO]) -> String {
        transcript.segments.map { entry in
            let time = timestamp(entry.startTime)
            if let raw = normalizedSpeaker(entry.speaker) {
                return "[\(time)] \(speakerDisplayName(rawLabel: raw, mappings: mappings)): \(entry.text)"
            }
            return "[\(time)] \(entry.text)"
        }.joined(separator: "\n")
    }

    /// SubRip subtitles; speaker names are inlined into the cue text when present.
    static func transcriptSRT(_ transcript: TranscriptDTO, mappings: [SpeakerLabelMappingDTO]) -> String {
        transcript.segments.enumerated().map { index, entry in
            let start = srtTimestamp(entry.startTime)
            let end = srtTimestamp(entry.endTime)
            var text = entry.text
            if let raw = normalizedSpeaker(entry.speaker) {
                text = "\(speakerDisplayName(rawLabel: raw, mappings: mappings)): \(text)"
            }
            return "\(index + 1)\n\(start) --> \(end)\n\(text)\n"
        }.joined(separator: "\n")
    }

    /// Markdown with a metadata header and consecutive same-speaker entries grouped into turns.
    static func transcriptMarkdown(_ transcript: TranscriptDTO, detail: RecordingDetailDTO) -> String {
        var lines = ["# \(detail.title)", ""]
        lines.append("- Date: \(detail.startDate.formatted(.iso8601))")
        lines.append("- Duration: \(timestamp(detail.duration))")
        if let language = transcript.detectedLanguage, !language.isEmpty {
            lines.append("- Language: \(language)")
        }
        if !detail.tags.isEmpty {
            lines.append("- Tags: \(detail.tags.joined(separator: ", "))")
        }
        lines.append("")

        var currentTurnName: String??
        for entry in transcript.segments {
            let name = normalizedSpeaker(entry.speaker).map {
                speakerDisplayName(rawLabel: $0, mappings: detail.speakerMappings)
            }
            if currentTurnName != .some(name) {
                if let name {
                    lines.append("**\(name)** · \(timestamp(entry.startTime))")
                    lines.append("")
                }
                currentTurnName = .some(name)
            }
            lines.append(entry.text)
            lines.append("")
        }
        return normalized(lines)
    }

    // MARK: - Summary

    static func summaryMarkdown(_ summary: SummaryDTO, detail: RecordingDetailDTO) -> String {
        var lines = ["# \(detail.title)", ""]
        lines.append("- Date: \(detail.startDate.formatted(.iso8601))")
        lines.append("- Duration: \(timestamp(detail.duration))")
        if !detail.tags.isEmpty {
            lines.append("- Tags: \(detail.tags.joined(separator: ", "))")
        }
        lines += ["", "## Overview", "", summary.overview, ""]

        if !summary.chapters.isEmpty {
            lines += ["## Chapters", ""]
            lines += summary.chapters.map { chapter in
                var line = "- [\(timestamp(chapter.startSeconds))] \(chapter.title)"
                if !chapter.summary.isEmpty { line += " — \(chapter.summary)" }
                return line
            }
            lines.append("")
        }
        if !summary.keyPoints.isEmpty {
            lines += ["## Key Points", ""]
            lines += summary.keyPoints.map { "- \($0)" }
            lines.append("")
        }
        if !summary.decisions.isEmpty {
            lines += ["## Decisions", ""]
            lines += summary.decisions.map { "- \($0)" }
            lines.append("")
        }
        if !summary.actionItems.isEmpty {
            lines += ["## Action Items", ""]
            lines += summary.actionItems.map { item in
                var line = "- [\(item.isCompleted ? "x" : " ")] \(item.task)"
                if let assignee = item.assignee { line += " (@\(assignee))" }
                if let deadline = item.deadline { line += " — Due: \(deadline)" }
                return line
            }
            lines.append("")
        }
        if !summary.followUps.isEmpty {
            lines += ["## Follow-ups", ""]
            lines += summary.followUps.map { "- \($0)" }
            lines.append("")
        }
        if !summary.yourTasks.isEmpty {
            lines += ["## Your Tasks", ""]
            lines += summary.yourTasks.map { "- \($0)" }
            lines.append("")
        }
        return normalized(lines)
    }

    // MARK: - Metadata

    /// Deterministic (sorted keys, ISO-8601 dates) JSON sidecar.
    static func metadataJSON(
        _ detail: RecordingDetailDTO,
        folderPath: [String],
        exportedAt: Date
    ) throws -> Data {
        let metadata = ExportMetadata(
            id: detail.id,
            title: detail.title,
            startDate: detail.startDate,
            endDate: detail.endDate,
            duration: detail.duration,
            language: detail.language,
            detectedLanguage: detail.transcript?.detectedLanguage,
            tags: detail.tags,
            folderPath: folderPath,
            meetingApp: detail.meetingApp,
            source: detail.source,
            speakers: orderedUniqueSpeakers(detail),
            hasTranscript: detail.transcript != nil,
            hasSummary: detail.summary != nil,
            exportedAt: exportedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(metadata)
    }

    // MARK: - Naming

    static func exportDirectoryName(for detail: RecordingDetailDTO) -> String {
        ExportFileNaming.exportDirectoryName(title: detail.title, startDate: detail.startDate)
    }

    // MARK: - Helpers

    /// Resolved display names in order of first appearance.
    static func orderedUniqueSpeakers(_ detail: RecordingDetailDTO) -> [String] {
        guard let transcript = detail.transcript else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for entry in transcript.segments {
            guard let raw = normalizedSpeaker(entry.speaker) else { continue }
            let name = speakerDisplayName(rawLabel: raw, mappings: detail.speakerMappings)
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    private static func normalizedSpeaker(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// "m:ss" with rolling minutes — matches the detail view's timestamp style.
    static func timestamp(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "HH:MM:SS,mmm" SubRip timestamp.
    static func srtTimestamp(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let total = Int(clamped)
        let millis = Int((clamped.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, millis)
    }

    private static func normalized(_ lines: [String]) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
