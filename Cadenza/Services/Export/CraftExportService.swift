import Foundation

@Observable @MainActor
final class CraftExportService {
    private let defaults: UserDefaults
    /// Scoped-key resolver, injected so tests pin the mapping explicitly.
    private let preferenceKey: (String) -> String
    var isExporting = false
    var lastError: String?

    init(defaults: UserDefaults = .standard,
         preferenceKey: @escaping (String) -> String = ActiveProfileDefaults.key) {
        self.defaults = defaults
        self.preferenceKey = preferenceKey
    }

    /// Closure to open a URL in Craft. Returns whether Launch Services accepted
    /// the request; only an accepted launch may be recorded in the local ledger.
    var openURLHandler: ((URL) -> Bool)?

    /// Closure to check app availability. Falls back to false.
    var checkAppAvailableHandler: (() -> Bool)?

    var spaceID: String {
        get { defaults.string(forKey: preferenceKey("craft.spaceID")) ?? "" }
        set { defaults.set(newValue, forKey: preferenceKey("craft.spaceID")) }
    }

    var folderID: String {
        get { defaults.string(forKey: preferenceKey("craft.folderID")) ?? "" }
        set { defaults.set(newValue, forKey: preferenceKey("craft.folderID")) }
    }

    var isAvailable: Bool {
        checkAppAvailableHandler?() ?? false
    }

    // MARK: - Exported ledger
    //
    // Craft is write-only (craftdocs:// URL scheme) — there is no API to ask
    // Craft what already exists, so bulk export dedup has to live client-side.

    private var exportedIDsKey: String { preferenceKey("craft.exportedRecordingIDs") }

    var exportedRecordingIDs: Set<UUID> {
        Set((defaults.stringArray(forKey: exportedIDsKey) ?? []).compactMap(UUID.init))
    }

    func markExported(_ id: UUID) {
        var stored = defaults.stringArray(forKey: exportedIDsKey) ?? []
        let value = id.uuidString
        guard !stored.contains(value) else { return }
        stored.append(value)
        defaults.set(stored, forKey: exportedIDsKey)
    }

    func exportRecording(_ recording: RecordingDetailDTO) async throws {
        guard isAvailable else {
            throw ExportError.craftNotInstalled
        }

        isExporting = true
        lastError = nil
        defer { isExporting = false }

        let markdown = buildMarkdown(for: recording)

        var components = URLComponents(string: "craftdocs://createdocument")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "title", value: recording.title),
            URLQueryItem(name: "content", value: markdown),
        ]

        if !spaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "spaceId", value: spaceID))
        }
        if !folderID.isEmpty {
            queryItems.append(URLQueryItem(name: "folder", value: folderID))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw ExportError.craftLinkCreationFailed
        }

        guard let handler = openURLHandler else {
            NSLog("[Craft] ERROR: openURLHandler is nil, cannot open Craft")
            throw ExportError.craftURLHandlerUnavailable
        }
        guard handler(url) else {
            throw ExportError.craftOpenFailed
        }
        markExported(recording.id)
    }

    // MARK: - Markdown Building

    private func buildMarkdown(for recording: RecordingDetailDTO) -> String {
        var parts: [String] = []

        if let summary = recording.summary {
            if !summary.overview.isEmpty {
                parts.append("## Overview\n\(summary.overview)")
            }

            if !summary.keyPoints.isEmpty {
                parts.append("## Key Points\n" + summary.keyPoints.map { "- \($0)" }.joined(separator: "\n"))
            }

            if !summary.actionItems.isEmpty {
                let items = summary.actionItems.map { item in
                    let assignee = item.assignee.map { " (@\($0))" } ?? ""
                    return "- [ ] \(item.task)\(assignee)"
                }
                parts.append("## Action Items\n" + items.joined(separator: "\n"))
            }

            if !summary.decisions.isEmpty {
                parts.append("## Decisions\n" + summary.decisions.map { "- \($0)" }.joined(separator: "\n"))
            }

            if !summary.yourTasks.isEmpty {
                parts.append("## Your Tasks\n" + summary.yourTasks.map { "- \($0)" }.joined(separator: "\n"))
            }

            if !summary.followUps.isEmpty {
                parts.append("## Follow-ups\n" + summary.followUps.map { "- \($0)" }.joined(separator: "\n"))
            }
        }

        if let transcript = recording.transcript, !transcript.fullText.isEmpty {
            parts.append("---\n\n## Transcript\n\(transcript.fullText)")
        }

        return parts.joined(separator: "\n\n")
    }
}
