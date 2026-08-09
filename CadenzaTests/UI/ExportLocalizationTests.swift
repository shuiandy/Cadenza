import Foundation
import Testing

/// 导出面（Phase 0）新增 UI surface 的本地化门禁：
/// - Settings / 归档 / 批量导出 / 详情页导出菜单与 toast 的英文 key 必须有 zh-Hans；
/// - Services 侧也必须使用英文 source key，避免 development language 为 en 时
///   回退到中文源串。视图层由 `ViewLayerLocalizationTests` 守门。
/// key 用显式清单而非源码解析——新增字符串时把 key 加进对应清单。
@Suite("Export Localization")
struct ExportLocalizationTests {

    private static let portableArchiveCapabilityKey =
        "A verifiable export of every recording, transcript, summary and chat — audio included. Cadenza cannot currently import this archive. Never contains API keys or account tokens."

    private static let automaticBackupKeys: [String] = [
        "Automatic recovery backups",
        "Cadenza keeps up to three startup recovery copies. This action clears copies for the current profile and from earlier versions without changing your active library.",
        "Clear Backups…",
        "Clearing…",
        "Clear all automatic recovery backups?",
        "This permanently deletes Cadenza's startup recovery copies for this profile, including backups from earlier versions. Your active library is not deleted.",
        "Clear Backups",
        "Automatic recovery backups were cleared.",
        "Some automatic recovery backups couldn't be cleared. Try again.",
        "Automatic recovery backups couldn't be cleared. Try again.",
    ]

    private static let englishKeysNeedingChinese: [String] = [
        "Export & Backup",
        "Export recordings to files",
        "Write transcripts, summaries and audio into one folder per recording.",
        "Scope",
        "All recordings",
        "Transcript (.txt)",
        "Subtitles (.srt)",
        "Transcript (.md)",
        "Summary",
        "Audio",
        "Choose Folder…",
        "Export recordings to files?",
        "Export %lld",
        "About %@ will be written to the chosen folder.",
        "Exported %lld recordings.",
        "Exported %lld recordings, %lld failed.",
        "Cancelled — %lld recordings were exported.",
        "Dismiss",
        "Export all data (Portable Archive)",
        portableArchiveCapabilityKey,
        "Include voice embeddings (speaker recognition data)",
        "Export Archive…",
        "Archived %lld recordings.",
        "Archived %lld recordings, %lld failed — see manifest.json.",
        "Show in Finder",
        "Archive export cancelled.",
        "Export Here",
        "No recordings to export",
        "Archive export was cancelled.",
        "Verifying %lld/%lld",
        "The disk filled up while writing the archive.",
        "Local Folder…",
        "…and %lld more",
        "Export is unavailable while the storage location is being changed.",
        // 详情页导出菜单与 toast（原为中文源串）
        "Summary (.md)",
        "Audio (.m4a)",
        "Export",
        "Exported to %@",
        "Export to %@ failed",
        "Export to %@ failed (%lld/%lld done)",
        "Exported %lld recordings to %@",
        "File exported",
        "File export failed",
        "Audio file missing: %@",
        "Recording not found (possibly deleted)",
        "Not enough disk space: about %@ needed, %@ available",
    ] + automaticBackupKeys

    private func loadCatalogStrings() throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        return try #require(catalog["strings"] as? [String: Any])
    }

    private func translation(_ strings: [String: Any], key: String, language: String) -> String? {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let lang = localizations[language] as? [String: Any],
              let stringUnit = lang["stringUnit"] as? [String: Any],
              let value = stringUnit["value"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    @Test func exportEnglishKeysHaveChineseLocalization() throws {
        let strings = try loadCatalogStrings()
        for key in Self.englishKeysNeedingChinese {
            #expect(
                translation(strings, key: key, language: "zh-Hans") != nil,
                "missing zh-Hans for key: \(key)"
            )
        }
    }

    @Test func automaticBackupUIHasEverySupportedLocalization() throws {
        let strings = try loadCatalogStrings()
        let languages = ["de", "es", "fr", "ja", "ko", "zh-Hans"]
        for key in Self.automaticBackupKeys {
            for language in languages {
                #expect(
                    translation(strings, key: key, language: language) != nil,
                    "missing \(language) for automatic backup key: \(key)"
                )
            }
        }
    }

    @Test func portableArchiveLimitationHasEverySupportedLocalization() throws {
        let strings = try loadCatalogStrings()
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            #expect(
                translation(
                    strings,
                    key: Self.portableArchiveCapabilityKey,
                    language: language
                ) != nil,
                "missing \(language) for portable archive limitation"
            )
        }
    }

}
