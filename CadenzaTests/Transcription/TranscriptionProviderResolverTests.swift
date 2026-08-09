import Foundation
import Testing
@testable import Cadenza

@MainActor
private final class TranscriptionProviderResolverSpy {
    var keys: [AIProvider: String] = [:]
    var supportedAppleLanguages: Set<String> = []
    var whisperState = LocalWhisperState(model: "base", isAvailable: false)

    private(set) var keyLookups: [AIProvider] = []
    private(set) var appleLanguageLookups: [String] = []
    private(set) var whisperStateLookupCount = 0

    func resetKeyLookups() {
        keyLookups.removeAll()
    }

    func makeResolver() -> TranscriptionProviderResolver {
        TranscriptionProviderResolver(
            apiKey: { [self] provider in
                keyLookups.append(provider)
                return keys[provider]
            },
            supportsAppleLanguage: { [self] language in
                appleLanguageLookups.append(language)
                return supportedAppleLanguages.contains(language)
            },
            localWhisperState: { [self] in
                whisperStateLookupCount += 1
                return whisperState
            }
        )
    }
}

@Suite("Exact transcription provider resolver", .serialized)
@MainActor
struct TranscriptionProviderResolverTests {
    @Test func appleSpeechFactoryOwnsAvailabilityBoundary() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productRoot = repoRoot.appendingPathComponent("Cadenza")
        let implementationURL = productRoot.appendingPathComponent("Services/Transcription/AppleSpeechTranscriber.swift")
        let enumerator = try #require(FileManager.default.enumerator(
            at: productRoot,
            includingPropertiesForKeys: nil
        ))

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard fileURL.resolvingSymlinksInPath()
                != implementationURL.resolvingSymlinksInPath() else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(
                !source.contains("AppleSpeechTranscriber"),
                "\(fileURL.lastPathComponent) bypasses AppleSpeechFactory"
            )
        }
    }

    @Test func appleSpeechDiagnosticsNeverLogRecognizedText() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Cadenza/Services/Transcription/AppleSpeechTranscriber.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("String(text.prefix"))
        #expect(!source.contains("text='%@'"))
        #expect(source.contains("characters=%d"))
    }

    @Test func appleSpeechUsesOnDeviceAnalyzerWithoutLegacyRecognitionAuthorization() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Cadenza/Services/Transcription/AppleSpeechTranscriber.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("SpeechAnalyzer"))
        #expect(source.contains("SpeechTranscriber"))
        #expect(!source.contains("SFSpeechRecognizer"))
        #expect(!source.contains("requestAuthorization"))
        #expect(!source.contains("authorizationStatus"))
    }

    @Test func missingValueUsesExplicitPostProcessingDefault() async throws {
        let spy = TranscriptionProviderResolverSpy()
        spy.supportedAppleLanguages = ["en"]

        let selection = try await spy.makeResolver().resolve(
            storedProviderRawValue: nil,
            defaultProvider: .apple,
            mode: .postProcessing,
            language: "en"
        )

        #expect(selection.provider == .apple)
        #expect(selection.apiKey == nil)
        #expect(selection.model == nil)
        #expect(spy.appleLanguageLookups == ["en"])
        #expect(spy.keyLookups.isEmpty)
    }

    @Test func missingValueUsesExplicitRealtimeDefault() async throws {
        let spy = TranscriptionProviderResolverSpy()
        spy.keys[.openai] = "  selected-key  "

        let selection = try await spy.makeResolver().resolve(
            storedProviderRawValue: nil,
            defaultProvider: .openai,
            mode: .realtime,
            language: "en"
        )

        #expect(selection.provider == .openai)
        #expect(selection.apiKey == "selected-key")
        #expect(selection.model == nil)
        #expect(spy.keyLookups == [.openai])
    }

    @Test func emptyValueUsesDefaultButWhitespaceValueIsInvalid() async throws {
        let emptySpy = TranscriptionProviderResolverSpy()
        emptySpy.supportedAppleLanguages = ["auto"]
        let selection = try await emptySpy.makeResolver().resolve(
            storedProviderRawValue: "",
            defaultProvider: .apple,
            mode: .postProcessing,
            language: "auto"
        )
        #expect(selection.provider == .apple)

        let whitespaceSpy = TranscriptionProviderResolverSpy()
        await #expect(throws: TranscriptionProviderResolutionError.invalidStoredProvider("   ")) {
            try await whitespaceSpy.makeResolver().resolve(
                storedProviderRawValue: "   ",
                defaultProvider: .apple,
                mode: .postProcessing,
                language: "auto"
            )
        }
        #expect(whitespaceSpy.keyLookups.isEmpty)
        #expect(whitespaceSpy.appleLanguageLookups.isEmpty)
        #expect(whitespaceSpy.whisperStateLookupCount == 0)
    }

    @Test func invalidNonemptyValueDoesNotCoerceToDefault() async {
        let spy = TranscriptionProviderResolverSpy()

        await #expect(throws: TranscriptionProviderResolutionError.invalidStoredProvider("unknown-provider")) {
            try await spy.makeResolver().resolve(
                storedProviderRawValue: "unknown-provider",
                defaultProvider: .apple,
                mode: .postProcessing,
                language: "en"
            )
        }

        #expect(spy.keyLookups.isEmpty)
        #expect(spy.appleLanguageLookups.isEmpty)
        #expect(spy.whisperStateLookupCount == 0)
    }

    @Test func unsupportedAppleLanguageNeverReadsCloudKeys() async {
        let spy = TranscriptionProviderResolverSpy()
        spy.keys = [.openai: "openai-key", .gemini: "gemini-key"]

        await #expect(throws: TranscriptionProviderResolutionError.unsupportedLanguage(.apple, language: "zz")) {
            try await spy.makeResolver().resolve(
                storedProviderRawValue: AIProvider.apple.rawValue,
                defaultProvider: .apple,
                mode: .postProcessing,
                language: "zz"
            )
        }

        #expect(spy.appleLanguageLookups == ["zz"])
        #expect(spy.keyLookups.isEmpty)
    }

    @Test func unavailableWhisperModelNeverReadsCloudKeys() async {
        let spy = TranscriptionProviderResolverSpy()
        spy.keys = [.openai: "openai-key", .gemini: "gemini-key"]
        spy.whisperState = LocalWhisperState(model: "small.en", isAvailable: false)

        await #expect(throws: TranscriptionProviderResolutionError.localModelUnavailable("small.en")) {
            try await spy.makeResolver().resolve(
                storedProviderRawValue: AIProvider.whisperLocal.rawValue,
                defaultProvider: .apple,
                mode: .postProcessing,
                language: "en"
            )
        }

        #expect(spy.whisperStateLookupCount == 1)
        #expect(spy.keyLookups.isEmpty)
    }

    @Test func missingOpenAIKeyNeverReadsGemini() async {
        let spy = TranscriptionProviderResolverSpy()
        spy.keys[.openai] = " \n "
        spy.keys[.gemini] = "gemini-key"

        for mode in [TranscriptionProviderMode.postProcessing, .realtime] {
            spy.resetKeyLookups()
            await #expect(throws: TranscriptionProviderResolutionError.missingAPIKey(.openai)) {
                try await spy.makeResolver().resolve(
                    storedProviderRawValue: AIProvider.openai.rawValue,
                    defaultProvider: .apple,
                    mode: mode,
                    language: "en"
                )
            }
            #expect(spy.keyLookups == [.openai])
        }
    }

    @Test func missingGeminiKeyNeverReadsOpenAI() async {
        let spy = TranscriptionProviderResolverSpy()
        spy.keys[.gemini] = nil
        spy.keys[.openai] = "openai-key"

        for mode in [TranscriptionProviderMode.postProcessing, .realtime] {
            spy.resetKeyLookups()
            await #expect(throws: TranscriptionProviderResolutionError.missingAPIKey(.gemini)) {
                try await spy.makeResolver().resolve(
                    storedProviderRawValue: AIProvider.gemini.rawValue,
                    defaultProvider: .apple,
                    mode: mode,
                    language: "en"
                )
            }
            #expect(spy.keyLookups == [.gemini])
        }
    }

    @Test func unsupportedCloudProvidersFailBeforeDependencies() async {
        for provider in [AIProvider.claude, .minimax] {
            for mode in [TranscriptionProviderMode.postProcessing, .realtime] {
                let spy = TranscriptionProviderResolverSpy()
                await #expect(throws: TranscriptionProviderResolutionError.unsupportedProvider(provider, mode: mode)) {
                    try await spy.makeResolver().resolve(
                        storedProviderRawValue: provider.rawValue,
                        defaultProvider: .apple,
                        mode: mode,
                        language: "en"
                    )
                }
                #expect(spy.keyLookups.isEmpty)
                #expect(spy.appleLanguageLookups.isEmpty)
                #expect(spy.whisperStateLookupCount == 0)
            }
        }
    }

    @Test func realtimeWhisperFailsBeforeModelOrKeyLookup() async {
        let spy = TranscriptionProviderResolverSpy()

        await #expect(throws: TranscriptionProviderResolutionError.unsupportedProvider(.whisperLocal, mode: .realtime)) {
            try await spy.makeResolver().resolve(
                storedProviderRawValue: AIProvider.whisperLocal.rawValue,
                defaultProvider: .openai,
                mode: .realtime,
                language: "en"
            )
        }

        #expect(spy.whisperStateLookupCount == 0)
        #expect(spy.keyLookups.isEmpty)
    }

    @Test func exactSuccessSelectionsCarryOnlyRequiredConfiguration() async throws {
        let appleSpy = TranscriptionProviderResolverSpy()
        appleSpy.supportedAppleLanguages = ["ja"]
        let apple = try await appleSpy.makeResolver().resolve(
            storedProviderRawValue: AIProvider.apple.rawValue,
            defaultProvider: .openai,
            mode: .postProcessing,
            language: "ja"
        )
        #expect(apple.provider == .apple)
        #expect(apple.apiKey == nil)
        #expect(apple.model == nil)

        let whisperSpy = TranscriptionProviderResolverSpy()
        whisperSpy.whisperState = LocalWhisperState(model: "small.en", isAvailable: true)
        let whisper = try await whisperSpy.makeResolver().resolve(
            storedProviderRawValue: AIProvider.whisperLocal.rawValue,
            defaultProvider: .apple,
            mode: .postProcessing,
            language: "en"
        )
        #expect(whisper.provider == .whisperLocal)
        #expect(whisper.apiKey == nil)
        #expect(whisper.model == "small.en")

        let cloudSpy = TranscriptionProviderResolverSpy()
        cloudSpy.keys = [.openai: " openai-key ", .gemini: " gemini-key "]
        let openAI = try await cloudSpy.makeResolver().resolve(
            storedProviderRawValue: AIProvider.openai.rawValue,
            defaultProvider: .apple,
            mode: .postProcessing,
            language: "en"
        )
        let gemini = try await cloudSpy.makeResolver().resolve(
            storedProviderRawValue: AIProvider.gemini.rawValue,
            defaultProvider: .apple,
            mode: .realtime,
            language: "en"
        )
        #expect(openAI.provider == .openai)
        #expect(openAI.apiKey == "openai-key")
        #expect(openAI.model == nil)
        #expect(gemini.provider == .gemini)
        #expect(gemini.apiKey == "gemini-key")
        #expect(gemini.model == nil)
        #expect(cloudSpy.keyLookups == [.openai, .gemini])
    }

    @Test func localizedErrorsNameAffectedConfiguration() {
        let cases: [(TranscriptionProviderResolutionError, String)] = [
            (.invalidStoredProvider("broken-value"), "broken-value"),
            (.unsupportedProvider(.claude, mode: .postProcessing), AIProvider.claude.displayName),
            (.unsupportedProvider(.minimax, mode: .realtime), AIProvider.minimax.displayName),
            (.unsupportedLanguage(.apple, language: "zz"), "zz"),
            (.localModelUnavailable("small.en"), "small.en"),
            (.missingAPIKey(.gemini), AIProvider.gemini.displayName),
        ]

        for (error, expectedName) in cases {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty)
            #expect(description.contains(expectedName))
        }
    }

    @Test func localizedErrorsBoundAndFlattenUntrustedConfigurationValues() {
        let raw = String(repeating: "secret", count: 30) + "\nsecond-line"
        let description = TranscriptionProviderResolutionError
            .invalidStoredProvider(raw)
            .errorDescription ?? ""

        #expect(!description.contains("\n"))
        #expect(!description.contains(raw))
        #expect(description.contains("…"))
    }
}
