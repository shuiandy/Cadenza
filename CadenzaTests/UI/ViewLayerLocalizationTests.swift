import Foundation
import Testing

@testable import Cadenza

/// 视图层本地化门禁。
///
/// 背景：`Cadenza/Views` 里曾经散落中文源串（`Text("发言分布")`、
/// `Button("删除")` 等）。developmentLanguage 是 en，这些 key 在 String Catalog
/// 里没有 en 列，英文（以及 ja/ko/fr/de/es）系统上直接把中文 key 原样渲染出来。
///
/// 两道门：
/// 1. `Cadenza/Views` 的字符串字面量里不得出现 CJK 表意文字——源串一律英文。
///    全角标点（"。" "，" "！"）不在拦截范围，它们是转录断句/朗读用的数据，
///    不是 UI 文案。
/// 2. 每个非空 catalog key 必须覆盖全部 knownRegions，避免任何受支持语言
///    静默回退到英文。
@Suite("View Layer Localization")
struct ViewLayerLocalizationTests {

    private static let knownRegions = ["zh-Hans", "ja", "ko", "fr", "de", "es"]

    /// 由中文源串翻转而来的英文 key（含复用的既有 key）。
    private static let viewKeysNeedingAllRegions: [String] = [
        // RecordingDetailView — 移入废纸篓 / 新建说话人弹窗
        "Move Recording to Trash?",
        "Move to Trash",
        "The recording will stay in Trash for %lld days. After that, it is removed from the active library and its Cadenza-owned audio and derived data are deleted. Automatic recovery backups may retain a copy until rotation or explicit deletion. You can restore it before removal.",
        "New Speaker",
        "New Speaker…",
        "Speaker Name",
        "Create a speaker for \"%@\" and assign it.",
        "Cancel",
        "Create",
        "Delete",
        // RecordingDetailView — 转录 / 摘要工具栏
        "Re-transcribe",
        "Transcribing...",
        "Identify speakers",
        "Refresh speaker identification",
        "Copy",
        "Copied",
        "Regenerate",
        "Generating…",
        "Start Transcription",
        "Processing...",
        "Generating summary...",
        // RecordingDetailView — 导出菜单
        "Export",
        "Transcript (.txt)",
        "Subtitles (.srt)",
        "Transcript (.md)",
        "Summary (.md)",
        "Audio (.m4a)",
        // RecordingDetailView — 导出 toast
        "Exported to %@",
        "Export to %@ failed",
        "File exported",
        "File export failed",
        "Audio file missing: %@",
        // RecordingDetailView — 头部与说话人时间线
        "Rename",
        "Speaker Distribution",
        "Speakers: %lld",
        "Other",
        "Probably %@",
        "Reset to \"%@\"",
        "Confirm %@ (%@)",
        // RecordingsContentView — 批量导出 toast
        "Exported %lld recordings.",
        "Exported %lld recordings, %lld failed.",
        "Export to %@ failed (%lld/%lld done)",
        "Exported %lld recordings to %@",
        // TabContentView / MainWindow — 处理状态
        "Processing complete",
        "Transcribing %lld%%",
        // SettingsView — 废纸篓保留策略
        "Trash",
        "Auto-empty Trash",
        "3 days",
        "7 days",
        "15 days",
        "30 days",
        "Deleted recordings move to Trash and are removed from the active library after the selected number of days. Cadenza-owned audio files and derived data are included; imported source files remain in their original location. Automatic recovery backups may retain copies until rotation or explicit deletion.",
        "Deleted recordings stay here for %lld days. After that, they are removed from the active library and their Cadenza-owned audio and derived data are deleted. Automatic recovery backups may retain copies until rotation or explicit deletion.",
        "This permanently removes %lld recording from the active library, including its Cadenza-owned audio and derived data. Existing automatic recovery backups may retain a copy until rotation or explicit deletion. This cannot be undone in the active library.",
        "This permanently removes all %lld recordings from the active library, including their Cadenza-owned audio and derived data. Existing automatic recovery backups may retain copies until rotation or explicit deletion. This cannot be undone in the active library.",
        "This permanently removes the recording from the active library, including its Cadenza-owned audio and derived data. Existing automatic recovery backups may retain a copy until rotation or explicit deletion. This cannot be undone in the active library.",
        // AppState — 删除事务失败和延迟清理反馈
        "Couldn't move the recording to Trash. It is still in your library.",
        "Couldn't permanently delete the recording. It is still in Trash.",
        "Couldn't empty Trash. Your recordings are still in Trash.",
        "Couldn't finish automatic Trash cleanup. Your recordings were kept.",
        "Deletion recovery needs attention. Keep Cadenza open, then try again.",
        "Deletion finished. File cleanup will retry automatically.",
        "Deletion is unavailable while storage is moving. Wait for the move to finish, then try again.",
        // Toast — VoiceOver 播报的标题/副标题连接符（CJK 用 "。"）
        "%@. %@",
        // Settings — user-name placeholder
        "Your name",
        // AppKit file panels and UserNotifications accept plain String, so
        // these call sites must resolve the catalog explicitly.
        "Select audio files to import",
        "Imported %lld recording.",
        "Imported %lld recordings.",
        "Imported %lld of %lld recordings.",
        "No recordings were imported. Try again.",
        "Import unavailable while storage is moving. Wait for the move to finish, then try again.",
        "Auto-recording started",
        "Recording “%@”",
        // RecordingEngine is a plain-String alert boundary; unknown AV/OS
        // failures must not leak untranslated implementation details.
        "Cadenza couldn't start recording. Try again.",
        "Cadenza couldn't start the microphone. Check the selected microphone and Microphone access in System Settings, then try again.",
        "Cadenza couldn't verify the recording storage location. Check the storage location in Settings, then try again.",
        "AI response failed: %@",
        // Recording overlay — suggested AI questions are plain String tuples.
        "I zoned out — catch me up on the last 2 minutes",
        "What was just asked of me?",
        "Did anyone just mention my name?",
        "What's the current disagreement on the table?",
        "What follow-up questions should I ask?",
        "Give me a meeting notes template",
        // AI Chat — follow-up suggestions are appended to a plain [String].
        "Who is responsible for each action item?",
        "What are the deadlines for these action items?",
        "What context led to these decisions?",
        "Were there any objections or alternatives discussed?",
        "What were the key action items?",
        "Were there any unresolved issues?",
        "Which follow-ups are most urgent?",
        "Who owns each follow-up?",
        "Can you go into more detail?",
        "What action items came from this?",
        "Compare this with other recent meetings",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 逐字符扫描：跳过 `//` 行注释，收集单行字符串字面量的内容。
    /// 遇到换行就丢弃未闭合的片段，因此多行字面量（`"""`）不会被当成字面量吞进来。
    private func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        var current: String?
        let iterator = Array(source)
        var index = 0

        while index < iterator.count {
            let character = iterator[index]
            if current == nil {
                if character == "/", index + 1 < iterator.count, iterator[index + 1] == "/" {
                    while index < iterator.count, iterator[index] != "\n" { index += 1 }
                    continue
                }
                if character == "\"" { current = ""; index += 1; continue }
                index += 1
            } else {
                if character == "\\", index + 1 < iterator.count {
                    current?.append(character)
                    current?.append(iterator[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { literals.append(current ?? ""); current = nil; index += 1; continue }
                if character == "\n" { current = nil; index += 1; continue }
                current?.append(character)
                index += 1
            }
        }
        return literals
    }

    private func containsCJKIdeograph(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    @Test func viewLayerHasNoChineseSourceStrings() throws {
        let viewsRoot = Self.repoRoot.appendingPathComponent("Cadenza/Views")
        let enumerator = try #require(
            FileManager.default.enumerator(at: viewsRoot, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        var scannedFiles = 0

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFiles += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for literal in stringLiterals(in: source) where containsCJKIdeograph(literal) {
                offenders.append("\(url.lastPathComponent): \"\(literal)\"")
            }
        }

        #expect(scannedFiles > 0, "no Swift files found under Cadenza/Views")
        #expect(
            offenders.isEmpty,
            """
            View-layer string literals must be English source strings; \
            translate in Localizable.xcstrings instead. Offenders: \
            \(offenders.joined(separator: ", "))
            """
        )
    }

    /// These non-View services feed status pills, alerts, discard notices and
    /// export errors. They are UI surfaces even though they live below Views.
    @Test func presentationFlowsOutsideViewsUseEnglishSourceStrings() throws {
        let relativePaths = [
            "Cadenza/App/AppState.swift",
            "Cadenza/Services/Recording/RecordingEngine.swift",
            "Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift",
            "Cadenza/Services/Export/BatchFileExporter.swift",
            "Cadenza/Services/Export/PortableArchive/PortableArchiveWriter.swift",
        ]
        var offenders: [String] = []

        for relativePath in relativePaths {
            let url = Self.repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            for literal in stringLiterals(in: source) where containsCJKIdeograph(literal) {
                offenders.append("\(relativePath): \"\(literal)\"")
            }
        }

        #expect(
            offenders.isEmpty,
            "User-visible presentation flows must use English catalog keys. Offenders: \(offenders.joined(separator: ", "))"
        )
    }

    @Test func flippedViewKeysCoverEveryKnownRegion() throws {
        let catalogURL = Self.repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in Self.viewKeysNeedingAllRegions {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                Issue.record("missing catalog entry for key: \(key)")
                continue
            }
            for region in Self.knownRegions {
                let value = (localizations[region] as? [String: Any])
                    .flatMap { $0["stringUnit"] as? [String: Any] }
                    .flatMap { $0["value"] as? String }
                #expect(
                    value?.isEmpty == false,
                    "missing \(region) translation for key: \(key)"
                )
            }
        }
    }

    @Test func plainStringPresentationAPIsResolveTheirCatalogKeysExplicitly() throws {
        let sourcesAndRequiredCalls: [(String, [String])] = [
            (
                "Cadenza/App/AppState.swift",
                ["panel.message = String(localized: \"Select audio files to import\")"]
            ),
            (
                "Cadenza/Views/Recordings/ImportRecordingView.swift",
                [
                    "panel.message = String(localized: \"Select audio files to import\")",
                    "label: LocalizedStringKey",
                ]
            ),
            (
                "Cadenza/Services/Meeting/AutoRecordScheduler.swift",
                [
                    "content.title = String(localized: \"Auto-recording started\")",
                    "content.body = String(localized: \"Recording “\\(meeting.title)”\")",
                ]
            ),
            (
                "Cadenza/Views/Chat/AIChatView.swift",
                [
                    "localized: \"No AI provider configured. Add an API key in Settings.\"",
                    "content: String(localized: \"Database not available.\")",
                    "String(localized: \"AI response failed: \\(error.localizedDescription)\")",
                    "help: LocalizedStringKey",
                    ".accessibilityLabel(Text(help))",
                    "String(localized: \"Who is responsible for each action item?\")",
                    "String(localized: \"What are the deadlines for these action items?\")",
                    "String(localized: \"What context led to these decisions?\")",
                    "String(localized: \"Were there any objections or alternatives discussed?\")",
                    "String(localized: \"What were the key action items?\")",
                    "String(localized: \"Were there any unresolved issues?\")",
                    "String(localized: \"Which follow-ups are most urgent?\")",
                    "String(localized: \"Who owns each follow-up?\")",
                    "String(localized: \"Can you go into more detail?\")",
                    "String(localized: \"What action items came from this?\")",
                    "String(localized: \"Compare this with other recent meetings\")",
                ]
            ),
            (
                "Cadenza/Views/Chat/FloatingAIChatButton.swift",
                [
                    "localized: \"No AI provider configured. Please add an API key in Settings.\"",
                    "content: String(localized: \"Database not available.\")",
                    "String(localized: \"AI response failed: \\(error.localizedDescription)\")",
                ]
            ),
            (
                "Cadenza/Views/Recordings/ProjectDetailView.swift",
                [
                    "briefError = String(localized: \"Could not load folder data.\")",
                    "briefError = String(localized: \"No recordings in this folder yet.\")",
                    "localized: \"No AI provider configured. Add an API key in Settings.\"",
                    "String(localized: \"AI response failed: \\(error.localizedDescription)\")",
                ]
            ),
            (
                "Cadenza/Views/Main/RecordingOverlayPanel.swift",
                [
                    "String(localized: \"I zoned out — catch me up on the last 2 minutes\")",
                    "String(localized: \"What was just asked of me?\")",
                    "String(localized: \"Did anyone just mention my name?\")",
                    "String(localized: \"What's the current disagreement on the table?\")",
                    "String(localized: \"What follow-up questions should I ask?\")",
                    "String(localized: \"Give me a meeting notes template\")",
                ]
            ),
            (
                "Cadenza/Views/TabBar/TabContentView.swift",
                [
                    "help: LocalizedStringKey",
                    ".accessibilityLabel(Text(help))",
                ]
            ),
            (
                "Cadenza/Views/Recordings/TrashContentView.swift",
                [
                    "help: LocalizedStringKey",
                    ".accessibilityLabel(Text(help))",
                ]
            ),
        ]

        for (relativePath, requiredCalls) in sourcesAndRequiredCalls {
            let source = try String(
                contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for requiredCall in requiredCalls {
                #expect(
                    source.contains(requiredCall),
                    "plain String presentation API bypasses localization in \(relativePath)"
                )
            }
        }

        let chineseResources = try #require(
            Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj")
        )
        let chineseBundle = try #require(Bundle(url: chineseResources))
        #expect(
            chineseBundle.localizedString(
                forKey: "Auto-recording started",
                value: nil,
                table: "Localizable"
            ) == "自动录音已开始"
        )
        let fixtureTitle = "Fictional Planning"
        let recordingFormat = chineseBundle.localizedString(
            forKey: "Recording “%@”",
            value: nil,
            table: "Localizable"
        )
        #expect(
            String(format: recordingFormat, fixtureTitle)
                == "正在录制“Fictional Planning”"
        )

        let overlayQuestionTranslations = [
            "I zoned out — catch me up on the last 2 minutes": "我走神了，帮我补上刚才 2 分钟的内容",
            "What was just asked of me?": "刚才问了我什么？",
            "Did anyone just mention my name?": "刚才有人提到我的名字吗？",
            "What's the current disagreement on the table?": "当前的分歧点是什么？",
            "What follow-up questions should I ask?": "我应该提出哪些跟进问题？",
            "Give me a meeting notes template": "给我一个会议记录模板",
        ]
        for (key, expected) in overlayQuestionTranslations {
            #expect(
                chineseBundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: "Localizable"
                ) == expected,
                "recording overlay question did not resolve through the zh-Hans runtime catalog: \(key)"
            )
        }

        let chatFollowUpTranslations = [
            "Who is responsible for each action item?": "每个待办事项由谁负责？",
            "What are the deadlines for these action items?": "这些待办事项的截止日期是什么？",
            "What context led to these decisions?": "做出这些决策的背景是什么？",
            "Were there any objections or alternatives discussed?": "有讨论过反对意见或替代方案吗？",
            "What were the key action items?": "主要待办事项是什么？",
            "Were there any unresolved issues?": "有未解决的问题吗？",
            "Which follow-ups are most urgent?": "哪些跟进事项最紧急？",
            "Who owns each follow-up?": "每项跟进事项由谁负责？",
            "Can you go into more detail?": "能详细说说吗？",
            "What action items came from this?": "由此产生了哪些待办事项？",
            "Compare this with other recent meetings": "与其他近期会议对比",
        ]
        for (key, expected) in chatFollowUpTranslations {
            #expect(
                chineseBundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: "Localizable"
                ) == expected,
                "AI chat follow-up did not resolve through the zh-Hans runtime catalog: \(key)"
            )
        }
    }

    /// Every extracted non-empty key must explicitly cover every language the app
    /// offers in Settings. This prevents a new string from silently shipping with
    /// an English fallback in only one of the supported locales.
    @Test func everyNonEmptyCatalogKeyHasEverySupportedLocalization() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalogURL = Self.repoRoot
                .appendingPathComponent("Cadenza/Resources")
                .appendingPathComponent(catalogName)
            let catalog = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
            )
            let strings = try #require(catalog["strings"] as? [String: Any])

            for (key, rawEntry) in strings where !key.isEmpty {
                let entry = try #require(rawEntry as? [String: Any])
                let localizations = entry["localizations"] as? [String: Any]
                for region in Self.knownRegions {
                    let localizedEntry = localizations?[region] as? [String: Any]
                    let stringUnit = localizedEntry?["stringUnit"] as? [String: Any]
                    let value = stringUnit?["value"] as? String
                    #expect(
                        value?.isEmpty == false,
                        "missing \(region) translation for \(catalogName) key: \(key)"
                    )
                }
            }
        }
    }

    @Test func softDeleteCopyCannotClaimImmediatePermanentDeletion() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Cadenza/Views/Recordings/RecordingDetailView.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains(".alert(\"Move Recording to Trash?\""))
        #expect(!source.contains(".alert(\"Delete Recording?\""))
        #expect(!source.contains(
            "This will permanently delete the recording and its transcript and summary."
        ))
    }
}

@MainActor
@Suite("Localized Date and Count Presentation")
struct LocalizedDateAndCountPresentationTests {
    private static let dateSurfacePaths = [
        "Cadenza/Views/Calendar/CalendarMonthView.swift",
        "Cadenza/Views/Recaps/RecapsListView.swift",
        "Cadenza/Views/Recordings/TrashContentView.swift",
        "Cadenza/Views/Recaps/RecapDetailView.swift",
        "Cadenza/Views/MenuBar/MenuBarView.swift",
        "Cadenza/Views/Recordings/RecordingDetailView.swift",
        "Cadenza/Views/Recordings/RecordingRow.swift",
        "Cadenza/Views/Calendar/CalendarEventBlock.swift",
        "Cadenza/Views/Calendar/CalendarDayView.swift",
        "Cadenza/Views/Calendar/CalendarWeekView.swift",
        "Cadenza/Views/Calendar/EventDetailSheet.swift",
        "Cadenza/Views/Calendar/CalendarToolbarView.swift",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func gregorianFixture() throws -> (date: Date, laterDate: Date, calendar: Calendar, timeZone: TimeZone) {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try #require(calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 5,
            hour: 17,
            minute: 7
        )))
        let laterDate = try #require(calendar.date(byAdding: .day, value: 4, to: date))
        return (date, laterDate, calendar, timeZone)
    }

    private static func normalizedSpacing(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func visibleDateSurfacesDoNotReintroduceFixedDateFormats() throws {
        for relativePath in Self.dateSurfacePaths {
            let source = try String(
                contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(!source.contains("DateFormatter()"), "fixed formatter in \(relativePath)")
            #expect(!source.contains(".dateFormat"), "fixed date format in \(relativePath)")
            #expect(
                !source.contains("count == 1 ? \"\" : \"s\""),
                "dynamic English plural suffix in \(relativePath)"
            )
        }
    }

    @Test func dateOrderAndHourCycleFollowLocale() throws {
        let fixture = try Self.gregorianFixture()
        let timeStyle = Date.FormatStyle.dateTime
            .hour(.defaultDigits(amPM: .abbreviated)).minute()

        let locales = (
            us: Locale(identifier: "en_US"),
            gb: Locale(identifier: "en_GB"),
            zh: Locale(identifier: "zh-Hans")
        )

        let usDate = CalendarToolbarView.dateTitle(
            for: fixture.date,
            viewMode: .day,
            locale: locales.us,
            calendar: fixture.calendar,
            timeZone: fixture.timeZone
        )
        let gbDate = CalendarToolbarView.dateTitle(
            for: fixture.date,
            viewMode: .day,
            locale: locales.gb,
            calendar: fixture.calendar,
            timeZone: fixture.timeZone
        )
        let zhDate = CalendarToolbarView.dateTitle(
            for: fixture.date,
            viewMode: .day,
            locale: locales.zh,
            calendar: fixture.calendar,
            timeZone: fixture.timeZone
        )
        #expect(usDate == "Wednesday, August 5, 2026")
        #expect(gbDate == "Wednesday, 5 August 2026")
        #expect(zhDate == "2026年8月5日 星期三")

        let usTime = LocalizedDateFormatting.string(
            from: fixture.date,
            style: timeStyle,
            locale: locales.us,
            calendar: fixture.calendar,
            timeZone: fixture.timeZone
        )
        let gbTime = LocalizedDateFormatting.string(
            from: fixture.date,
            style: timeStyle,
            locale: locales.gb,
            calendar: fixture.calendar,
            timeZone: fixture.timeZone
        )
        let zhTime = LocalizedDateFormatting.string(
            from: fixture.date,
            style: timeStyle,
            locale: locales.zh,
            calendar: fixture.calendar,
            timeZone: fixture.timeZone
        )
        #expect(Self.normalizedSpacing(usTime) == "5:07 PM")
        #expect(gbTime == "17:07")
        #expect(zhTime == "17:07")
    }

    @Test func localizedDateIntervalPreservesLocaleOrder() throws {
        let fixture = try Self.gregorianFixture()
        let locales = [
            "en_US": "Aug 5 – 9, 2026",
            "en_GB": "5 – 9 Aug 2026",
            "zh-Hans": "2026/8/5 – 2026/8/9",
        ]

        for (identifier, expected) in locales {
            let result = LocalizedDateFormatting.interval(
                from: fixture.date,
                to: fixture.laterDate,
                dateStyle: .medium,
                timeStyle: .none,
                locale: Locale(identifier: identifier),
                calendar: fixture.calendar,
                timeZone: fixture.timeZone
            )
            #expect(Self.normalizedSpacing(result) == expected, "locale: \(identifier), got: \(result)")
        }
    }

    @Test func eventAndRecordingCountsUseStableLocalizedKeys() {
        let en = Locale(identifier: "en_US")
        let zh = Locale(identifier: "zh-Hans")

        #expect(CalendarMonthView.eventCountText(1, locale: en) == "1 event")
        #expect(CalendarMonthView.eventCountText(2, locale: en) == "2 events")
        #expect(CalendarMonthView.eventCountText(1, locale: zh) == "1 个事件")
        #expect(CalendarMonthView.eventCountText(2, locale: zh) == "2 个事件")

        #expect(RecapsListView.recordingCountText(1, locale: en) == "1 recording")
        #expect(RecapsListView.recordingCountText(2, locale: en) == "2 recordings")
        #expect(RecapsListView.recordingCountText(1, locale: zh) == "1 个录音")
        #expect(RecapsListView.recordingCountText(2, locale: zh) == "2 个录音")

        let oneRecording = TrashContentView.emptyTrashMessage(recordingCount: 1, locale: zh)
        let twoRecordings = TrashContentView.emptyTrashMessage(recordingCount: 2, locale: zh)
        let permanentDelete = TrashContentView.permanentDeleteMessage(locale: zh)
        #expect(oneRecording == "这会从当前资料库中永久移除 1 条录音，包括 Cadenza 创建的音频和派生数据。现有自动恢复备份可能会保留副本，直到备份轮换或被明确删除。此操作在当前资料库中无法撤销。")
        #expect(twoRecordings == "这会从当前资料库中永久移除全部 2 条录音，包括 Cadenza 创建的音频和派生数据。现有自动恢复备份可能会保留副本，直到备份轮换或被明确删除。此操作在当前资料库中无法撤销。")
        #expect(permanentDelete == "这会从当前资料库中永久移除该录音，包括 Cadenza 创建的音频和派生数据。现有自动恢复备份可能会保留副本，直到备份轮换或被明确删除。此操作在当前资料库中无法撤销。")

        let trashRetention = TrashContentView.retentionDescription(retentionDays: 7, locale: zh)
        let moveToTrash = RecordingDetailView.moveToTrashMessage(retentionDays: 7, locale: zh)
        #expect(trashRetention == "已删除的录音会在此保留 7 天。之后，它们会从当前资料库中移除，Cadenza 创建的音频和派生数据也会被删除。自动恢复备份可能会保留副本，直到备份轮换或被明确删除。")
        #expect(moveToTrash == "录音会在废纸篓中保留 7 天。之后，它会从当前资料库中移除，Cadenza 创建的音频和派生数据也会被删除。自动恢复备份可能会保留副本，直到备份轮换或被明确删除。移除前你可以恢复录音。")
        #expect(TrashContentView.retentionDescription(retentionDays: 0, locale: zh) == trashRetention)
        #expect(RecordingDetailView.moveToTrashMessage(retentionDays: 0, locale: zh) == moveToTrash)
    }

    @Test func deletionFeedbackUsesStableChineseCatalogCopy() {
        let zh = Locale(identifier: "zh-Hans")
        let expected: [(RecordingDeletionFeedback, String)] = [
            (.moveToTrashFailed, "无法将录音移到废纸篓。录音仍保留在资料库中。"),
            (.permanentDeletionFailed, "无法永久删除录音。录音仍保留在废纸篓中。"),
            (.emptyTrashFailed, "无法清空废纸篓。录音仍保留在废纸篓中。"),
            (.automaticTrashCleanupFailed, "无法完成废纸篓自动清理。录音已保留。"),
            (.recoveryNeedsAttention, "删除恢复需要处理。请保持 Cadenza 打开，然后重试。"),
            (.secureCleanupPending, "删除已完成。系统会自动重试文件清理。"),
            (.blockedByStorageMigration, "正在移动存储位置，暂时无法删除。请等待移动完成后重试。"),
        ]

        for (feedback, title) in expected {
            #expect(RecordingDeletionToastPresentation.make(for: feedback, locale: zh).title == title)
        }
    }
}
