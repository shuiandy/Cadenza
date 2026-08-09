import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Cadenza

@Suite("Web Sync Localization")
struct WebSyncLocalizationTests {
    private static let supportedLocales = ["de", "es", "fr", "ja", "ko", "zh-Hans"]
    private static let statusKeys = [
        "Retry now",
        "Sync failed. Retrying automatically.",
        "Syncing to Web…",
        "Web sync is automatic.",
    ]

    @Test func accountSyncVisibleStringsHaveChineseLocalization() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let localizedStrings = try #require(catalog["strings"] as? [String: Any])

        let sourceURLs = [
            repoRoot.appendingPathComponent("Cadenza/Views/Main/MainWindow.swift"),
            repoRoot.appendingPathComponent("Cadenza/Views/Settings/IntegrationsSettingsView.swift"),
            repoRoot.appendingPathComponent("Cadenza/Views/Settings/SubscriptionSection.swift"),
        ]
        let visibleKeys = try sourceURLs.flatMap { url in
            let source = try String(contentsOf: url, encoding: .utf8)
            return try Self.visibleEnglishLocalizationKeys(in: source)
        }

        let allowedVerbatimKeys: Set<String> = [
            "Cadenza",
            "Craft",
            "Gemini",
            "Google Calendar",
            "Google Drive",
            "Google OAuth2 Credentials",
            "Notion",
            "OneDrive",
            "OpenAI",
            "Zoom",
        ]

        var failures: [String] = []
        for key in Set(visibleKeys).sorted() where !allowedVerbatimKeys.contains(key) {
            guard let entry = localizedStrings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let zh = localizations["zh-Hans"] as? [String: Any],
                  let stringUnit = zh["stringUnit"] as? [String: Any],
                  let value = stringUnit["value"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                failures.append("\(key) is missing zh-Hans")
                continue
            }

            if value == key {
                failures.append("\(key) has a verbatim zh-Hans value")
            }
        }

        if !failures.isEmpty {
            Issue.record("Web sync localization failures:\n\(failures.joined(separator: "\n"))")
        }
    }

    @Test func statusStringsCoverEverySupportedLocale() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in Self.statusKeys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in Self.supportedLocales {
                let localization = try #require(localizations[locale] as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                let value = try #require(unit["value"] as? String)
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(value != key)
            }
        }
    }

    @Test func accountRowUsesSafePresentationBoundaryAndPublicRetry() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Cadenza/Views/Settings/IntegrationsSettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("WebSyncStatusPresentation.resolve("))
        #expect(source.contains("WebSyncStatusRow("))
        #expect(source.contains("presentation: webSyncStatus"))
        #expect(source.contains("appState.webSync.retryNow()"))
        #expect(!source.contains("Text(appState.webSync.lastError"))
        #expect(!source.contains("Text(verbatim: appState.webSync.lastError"))
    }

    private static func visibleEnglishLocalizationKeys(in source: String) throws -> [String] {
        let patterns = [
            #"String\(localized:\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"Text\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"Button\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"Label\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"Toggle\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"Section\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"\.alert\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"\.confirmationDialog\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"\.help\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"ContentUnavailableView\(\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"SettingsSectionCard\(\s*title:\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"SettingsSectionCard\(\s*title:\s*\"(?:[^\"\\]|\\.)*\"\s*,\s*subtitle:\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"SettingsPageLayout\(\s*title:\s*\"((?:[^\"\\]|\\.)*)\""#,
            #"SettingsPageLayout\(\s*title:\s*\"(?:[^\"\\]|\\.)*\"\s*,\s*subtitle:\s*\"((?:[^\"\\]|\\.)*)\""#,
        ]
        let dynamicMarkers = ["\\(", "%@", "%lld"]
        var keys: [String] = []

        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: sourceRange) {
                let matchRange = match.range(at: 1)
                guard matchRange.location != NSNotFound,
                      let range = Range(matchRange, in: source)
                else { continue }

                let key = String(source[range])
                let containsCJK = key.unicodeScalars.contains { scalar in
                    (0x4E00...0x9FFF).contains(scalar.value)
                }
                guard !containsCJK,
                      key.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil,
                      !dynamicMarkers.contains(where: key.contains)
                else { continue }
                keys.append(key)
            }
        }

        return keys
    }
}

@Suite("Web Sync Status Presentation")
struct WebSyncStatusPresentationTests {
    @Test func liveStateHasStablePrecedence() {
        #expect(
            WebSyncStatusPresentation.resolve(
                isSyncing: true,
                lastError: "stale-error"
            ) == .syncing
        )
        #expect(
            WebSyncStatusPresentation.resolve(
                isSyncing: false,
                lastError: "failure"
            ) == .retrying
        )
        #expect(
            WebSyncStatusPresentation.resolve(
                isSyncing: false,
                lastError: nil
            ) == .automatic
        )
    }

    @Test func rawCoordinatorErrorCanaryNeverBecomesVisibleCopy() {
        let rawCanary = "RAW-WEB-SYNC-PROVIDER-ERROR-CANARY"
        let presentation = WebSyncStatusPresentation.resolve(
            isSyncing: false,
            lastError: rawCanary
        )

        #expect(presentation == .retrying)
        for identifier in ["en", "de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let visibleCopy = presentation.localizedTitle(
                locale: Locale(identifier: identifier)
            )
            #expect(!visibleCopy.contains(rawCanary))
            #expect(!visibleCopy.contains("PROVIDER-ERROR"))
        }
    }

    @Test func maximumSupportedScaleUsesStackedLayout() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )

        #expect(scale == 3.105)
        #expect(!WebSyncStatusLayoutPolicy.usesStackedLayout(scale: 1))
        #expect(WebSyncStatusLayoutPolicy.usesStackedLayout(scale: scale))
    }

    @MainActor @Test func retryRowStaysBoundedAtMaximumScaleInEveryLocale() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let contentWidth: CGFloat = 612

        for identifier in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let root = WebSyncStatusRow(
                presentation: .retrying,
                canRetry: true,
                retry: {}
            )
                .environment(\.uiScale, scale)
                .environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.locale, Locale(identifier: identifier))
                .frame(width: contentWidth, alignment: .leading)
            let host = NSHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()

            #expect(host.fittingSize.width <= contentWidth + 0.5)
            #expect(host.fittingSize.height > 44)
            #expect(host.fittingSize.height.isFinite)
        }
    }
}

/// The subscription surface renders interpolated strings too, whose catalogue
/// keys carry format specifiers the source scan deliberately skips. They are
/// pinned by name so a missing translation still fails.
@Suite("Subscription Localization")
struct SubscriptionLocalizationTests {
    private static let interpolatedKeys = [
        "Grace period until %@",
        "Not recognized by this version (%@)",
        "resets %@",
        "window not recognized (%@)",
        "includes %@ in progress",
        "%@ used · unlimited",
        "%@ of %@",
        "%lld recordings",
    ]

    @Test func interpolatedSubscriptionStringsHaveChineseLocalization() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])

        var failures: [String] = []
        for key in Self.interpolatedKeys {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let zh = localizations["zh-Hans"] as? [String: Any],
                  let unit = zh["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                failures.append("\(key) is missing zh-Hans")
                continue
            }
            if value == key {
                failures.append("\(key) has a verbatim zh-Hans value")
            }
        }
        if !failures.isEmpty {
            Issue.record("Subscription localization failures:\n\(failures.joined(separator: "\n"))")
        }
    }
}
