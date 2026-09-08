import Testing
import Foundation
@testable import Cadenza

@Suite("Enum Types")
struct EnumTests {

    // MARK: - RecordingState

    @Test func recordingStateValues() {
        let idle: RecordingState = .idle
        let recording: RecordingState = .recording
        let paused: RecordingState = .paused
        let transcribing: RecordingState = .transcribing
        let summarizing: RecordingState = .summarizing
        // Just verify all cases exist and are distinct
        let all: Set<String> = ["\(idle)", "\(recording)", "\(paused)", "\(transcribing)", "\(summarizing)"]
        #expect(all.count == 5)
    }

    // MARK: - AIProvider

    @Test func aiProviderRawValues() {
        #expect(AIProvider.openai.rawValue == "openai")
        #expect(AIProvider.claude.rawValue == "claude")
        #expect(AIProvider.gemini.rawValue == "gemini")
    }

    @Test func aiProviderDisplayName() {
        #expect(AIProvider.openai.displayName == "OpenAI")
        #expect(AIProvider.claude.displayName == "Claude (Anthropic)")
        #expect(AIProvider.gemini.displayName == "Gemini (Google)")
    }

    @Test func aiProviderDefaultModel() {
        #expect(AIProvider.openai.defaultModel == "gpt-5.6-sol")
        #expect(AIProvider.openai.defaultChatModel == "gpt-5.6-terra")
        #expect(!AIProvider.claude.defaultModel.isEmpty)
        #expect(!AIProvider.gemini.defaultModel.isEmpty)
    }

    @Test func aiProviderDefaultModels() {
        for provider in AIProvider.allCases {
            #expect(!provider.defaultModel.isEmpty)
        }
    }

    @Test func geminiDefaultsUseCurrentStableModel() {
        #expect(AIProvider.gemini.defaultModel == "gemini-3.7-flash")
        #expect(AIProvider.gemini.defaultChatModel == "gemini-3.7-flash")
        // Transcription no longer borrows the flash model: it runs on the
        // dedicated ASR, which also decides that the batch path speaks the
        // Interactions API rather than generateContent.
        #expect(AIProvider.gemini.defaultTranscriptionModel == "gemini-3.5-transcribe")
        #expect(GeminiTranscribeInteraction.isTranscribeModel(AIProvider.gemini.defaultTranscriptionModel))
        #expect(GeminiTranscribeInteraction.isTranscribeModel(AIProvider.gemini.defaultRealtimeModel))
        #expect(GeminiTranscribeInteraction.isTranscribeModel(AIProvider.gemini.defaultModel) == false)
    }

    @Test func aiProviderIconName() {
        #expect(AIProvider.openai.iconName == "openai-icon")
        #expect(AIProvider.claude.iconName == "claude-icon")
        #expect(AIProvider.gemini.iconName == "gemini-icon")
    }

    @Test func aiProviderApiKeyPlaceholder() {
        #expect(AIProvider.openai.apiKeyPlaceholder.starts(with: "sk-"))
        #expect(AIProvider.claude.apiKeyPlaceholder.starts(with: "sk-ant-"))
        #expect(AIProvider.gemini.apiKeyPlaceholder.starts(with: "AIza"))
    }

    @Test func aiProviderCaseIterable() {
        #expect(AIProvider.allCases.count == 6)
    }

    @Test func aiProviderCodable() throws {
        for provider in AIProvider.allCases {
            let data = try JSONEncoder().encode(provider)
            let decoded = try JSONDecoder().decode(AIProvider.self, from: data)
            #expect(decoded == provider)
        }
    }

    @Test func aiProviderTranscriptionSupport() {
        #expect(AIProvider.openai.supportsTranscription)
        #expect(!AIProvider.claude.supportsTranscription)
        #expect(AIProvider.gemini.supportsTranscription)
        #expect(AIProvider.whisperLocal.supportsTranscription)
    }

    // MARK: - TranscriptionLanguage

    @Test func transcriptionLanguageAutoRawValue() {
        #expect(TranscriptionLanguage.auto.rawValue == "auto")
        #expect(TranscriptionLanguage.english.rawValue == "en")
        #expect(TranscriptionLanguage.chinese.rawValue == "zh")
    }

    @Test func transcriptionLanguageCaseIterable() {
        #expect(TranscriptionLanguage.allCases.count == 20)
    }

    @Test func transcriptionLanguageDisplayName() {
        #expect(TranscriptionLanguage.auto.displayName == "Auto Detect")
        #expect(TranscriptionLanguage.english.displayName == "English")
        #expect(TranscriptionLanguage.chinese.displayName == "中文")
    }

    // MARK: - MeetingType

    @Test func meetingTypeCaseIterable() {
        #expect(MeetingType.allCases.count == 10)
    }

    @Test func meetingTypeDisplayName() {
        #expect(MeetingType.oneOnOne.displayName == "1:1")
        #expect(MeetingType.standup.displayName == "Standup")
        #expect(MeetingType.general.displayName == "General")
    }

    @Test func meetingTypeSummaryGuidance() {
        #expect(!MeetingType.oneOnOne.summaryGuidance.isEmpty)
        #expect(MeetingType.general.summaryGuidance.isEmpty) // General has no guidance
    }

    // MARK: - MeetingApp

    @Test func meetingAppDisplayName() {
        #expect(MeetingApp.zoom.displayName == "Zoom")
        #expect(MeetingApp.teams.displayName == "Microsoft Teams")
        #expect(MeetingApp.googleMeet.displayName == "Google Meet")
    }

    @Test func meetingAppBundleIdentifiers() {
        #expect(!MeetingApp.zoom.bundleIdentifiers.isEmpty)
        #expect(!MeetingApp.teams.bundleIdentifiers.isEmpty)
        #expect(MeetingApp.googleMeet.bundleIdentifiers.isEmpty) // Browser-based
    }

    @Test func meetingAppCaseIterable() {
        #expect(MeetingApp.allCases.count == 6)
    }

    // MARK: - CalendarSource

    @Test func calendarSourceRawValues() {
        #expect(CalendarSource.apple.rawValue == "apple")
        #expect(CalendarSource.google.rawValue == "google")
        #expect(CalendarSource.zoom.rawValue == "zoom")
    }

    @Test func calendarSourceDisplayName() {
        #expect(CalendarSource.apple.displayName == "Apple Calendar")
        #expect(CalendarSource.google.displayName == "Google Calendar")
        #expect(CalendarSource.zoom.displayName == "Zoom")
    }

    // MARK: - SettingsCategory

    @Test func settingsCategoryCaseIterable() {
        #expect(SettingsCategory.allCases.count == 6)
    }

    @Test func settingsCategoryTitleAndIcon() {
        for cat in SettingsCategory.allCases {
            #expect(!cat.title.isEmpty)
            #expect(!cat.icon.isEmpty)
        }
    }

    // MARK: - ChatRole

    @Test func chatRoleRawValues() {
        #expect(ChatRole.user.rawValue == "user")
        #expect(ChatRole.assistant.rawValue == "assistant")
    }

    // MARK: - SummaryDetailLevel

    @Test func summaryDetailLevelDisplayName() {
        #expect(SummaryDetailLevel.highlights.displayName == "Brief")
        #expect(SummaryDetailLevel.detailed.displayName == "Standard")
        #expect(SummaryDetailLevel.fullBreakdown.displayName == "Detailed")
    }

    @Test func summaryDetailLevelPreservesSavedValuesAndStandardFallback() throws {
        let suite = "SummaryDetailLevelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SummaryDetailLevel.load(defaults: defaults) == .detailed)
        for (raw, expected) in [("highlights", SummaryDetailLevel.highlights),
                                ("detailed", .detailed), ("fullBreakdown", .fullBreakdown)] {
            defaults.set(raw, forKey: SummaryDetailLevel.defaultsKey)
            #expect(SummaryDetailLevel.load(defaults: defaults) == expected)
        }
        defaults.set("unknown-future-level", forKey: SummaryDetailLevel.defaultsKey)
        #expect(SummaryDetailLevel.load(defaults: defaults) == .detailed)
    }

    // MARK: - AppTheme

    @Test func appThemeRawValues() {
        #expect(AppTheme.system.rawValue == "system")
        #expect(AppTheme.light.rawValue == "light")
        #expect(AppTheme.dark.rawValue == "dark")
    }

    // MARK: - AttendeeStatus

    @Test func attendeeStatusValues() {
        #expect(AttendeeStatus.accepted.icon == "checkmark.circle.fill")
        #expect(AttendeeStatus.declined.icon == "xmark.circle.fill")
        #expect(AttendeeStatus.tentative.icon == "questionmark.circle.fill")
    }
}
