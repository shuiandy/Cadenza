import CryptoKit
import Foundation

extension Notification.Name {
    static let cadenzaRecordingsChanged = Notification.Name("cadenzaRecordingsChanged")
}

struct MarkdownMirrorRunSummary: Equatable, Sendable {
    var written = 0
    var unchanged = 0
    var conflicts = 0
    var failed = 0
}

actor MarkdownMirrorService {
    private struct LedgerEntry: Codable, Sendable {
        let recordingID: UUID
        var filename: String
        var lastWrittenSHA256: String
        var writtenAt: Date
    }

    private let store: RecordingsStore
    private let defaults: UserDefaults
    private let ledgerKey: String
    private let directoryProvider: @Sendable () -> URL?

    init(
        store: RecordingsStore,
        defaultsSuiteName: String? = nil,
        ledgerKey: String = MarkdownMirrorLocationManager.ledgerDefaultsKey,
        directoryProvider: @escaping @Sendable () -> URL? = { MarkdownMirrorLocationManager.directory }
    ) {
        self.store = store
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.ledgerKey = ledgerKey
        self.directoryProvider = directoryProvider
    }

    func rebuildAll(includeTranscript: Bool) async -> MarkdownMirrorRunSummary {
        await refresh(recordingIDs: nil, includeTranscript: includeTranscript, requireEnabled: false)
    }

    func refreshIfEnabled(recordingIDs: Set<UUID>? = nil) async -> MarkdownMirrorRunSummary {
        guard defaults.bool(forKey: MarkdownMirrorLocationManager.enabledDefaultsKey) else {
            return MarkdownMirrorRunSummary()
        }
        return await refresh(
            recordingIDs: recordingIDs,
            includeTranscript: defaults.bool(forKey: MarkdownMirrorLocationManager.includeTranscriptDefaultsKey),
            requireEnabled: true
        )
    }

    private func refresh(
        recordingIDs: Set<UUID>?,
        includeTranscript: Bool,
        requireEnabled: Bool
    ) async -> MarkdownMirrorRunSummary {
        if requireEnabled,
           !defaults.bool(forKey: MarkdownMirrorLocationManager.enabledDefaultsKey) {
            return MarkdownMirrorRunSummary()
        }
        guard let directory = directoryProvider() else {
            return MarkdownMirrorRunSummary(failed: 1)
        }

        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("[MarkdownMirror] failed to create directory: %@", error.localizedDescription)
            return MarkdownMirrorRunSummary(failed: 1)
        }

        let records = await store.fetchMarkdownMirrorRecords(recordingIDs: recordingIDs)
        var ledger = loadLedger()
        var summary = MarkdownMirrorRunSummary()

        for record in records {
            if Task.isCancelled { break }
            if requireEnabled,
               !defaults.bool(forKey: MarkdownMirrorLocationManager.enabledDefaultsKey) { break }
            let id = record.detail.id
            let content = Self.render(record, includeTranscript: includeTranscript)
            let newHash = Self.sha256(content)
            let filename = ledger[id]?.filename ?? Self.filename(for: record.detail)
            let fileURL = directory.appendingPathComponent(filename, isDirectory: false)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let existingData = try? Data(contentsOf: fileURL) else {
                    summary.failed += 1
                    continue
                }
                let existingHash = Self.sha256(existingData)
                guard let entry = ledger[id], existingHash == entry.lastWrittenSHA256 else {
                    summary.conflicts += 1
                    continue
                }
                if existingHash == newHash {
                    summary.unchanged += 1
                    continue
                }
            } else if ledger[id] != nil {
                // A user may deliberately remove a mirrored note. Do not
                // silently recreate it. Re-selecting the folder explicitly
                // resets the ledger if the folder location changed.
                summary.conflicts += 1
                continue
            }

            do {
                try Data(content.utf8).write(to: fileURL, options: .atomic)
                ledger[id] = LedgerEntry(
                    recordingID: id,
                    filename: filename,
                    lastWrittenSHA256: newHash,
                    writtenAt: Date()
                )
                summary.written += 1
            } catch {
                NSLog("[MarkdownMirror] failed to write recording %@: %@", id.uuidString, error.localizedDescription)
                summary.failed += 1
            }
        }
        persistLedger(ledger)
        return summary
    }

    private func loadLedger() -> [UUID: LedgerEntry] {
        guard let data = defaults.data(forKey: ledgerKey),
              let entries = try? JSONDecoder().decode([LedgerEntry].self, from: data) else {
            return [:]
        }
        var ledger: [UUID: LedgerEntry] = [:]
        for entry in entries.sorted(by: { $0.writtenAt > $1.writtenAt })
            where ledger[entry.recordingID] == nil {
            ledger[entry.recordingID] = entry
        }
        return ledger
    }

    private func persistLedger(_ ledger: [UUID: LedgerEntry]) {
        let entries = ledger.values.sorted { $0.recordingID.uuidString < $1.recordingID.uuidString }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: ledgerKey)
    }

    static func render(_ record: MarkdownMirrorRecordDTO, includeTranscript: Bool) -> String {
        let detail = record.detail
        let source = detail.source ?? "unknown"
        var lines = [
            "---",
            "id: \"\(detail.id.uuidString)\"",
            "source: \"\(yamlEscape(source))\"",
            "external_provider: \(record.externalProvider.map { "\"\(yamlEscape($0))\"" } ?? "null")",
            "external_id: \(record.externalID.map { "\"\(yamlEscape($0))\"" } ?? "null")",
            "updated_at: \"\((detail.updatedAt ?? detail.startDate).formatted(.iso8601))\"",
            "tags:",
        ]
        if detail.tags.isEmpty {
            lines.append("  []")
        } else {
            lines.append(contentsOf: detail.tags.map { "  - \"\(yamlEscape($0))\"" })
        }
        lines += ["---", "", "# \(detail.title)", ""]

        if let summary = detail.summary {
            lines += ["## Summary", "", summary.overview, ""]
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
        }

        if includeTranscript, let transcript = detail.transcript, !transcript.fullText.isEmpty {
            lines += ["## Transcript", "", transcript.fullText, ""]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func filename(for detail: RecordingDetailDTO) -> String {
        let date = ExportFileNaming.dateComponent(for: detail.startDate)
        let bounded = ExportFileNaming.sanitizedTitle(detail.title)
        return "\(date) - \(bounded) - \(detail.id.uuidString).md"
    }

    private static func yamlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
