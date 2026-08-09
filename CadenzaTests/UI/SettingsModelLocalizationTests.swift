import Foundation
import Testing

@Suite("Settings Model Localization")
struct SettingsModelLocalizationTests {
    @Test func modelGuidanceHasChineseLocalization() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let keys = [
            "Recommended: %@",
            "Summary model",
            "Use recommended",
            "Used for summaries. AI chat models are selected in chat.",
        ]

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
            let stringUnit = try #require(chinese["stringUnit"] as? [String: Any])
            let value = try #require(stringUnit["value"] as? String)

            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(value != key)
        }
    }
}
