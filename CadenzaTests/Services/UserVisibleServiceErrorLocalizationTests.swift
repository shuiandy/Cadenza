import Foundation
import Testing
@testable import Cadenza

@Suite("User-visible service error localization")
struct UserVisibleServiceErrorLocalizationTests {
    private static let rawCanary = #"RAW-CANARY-{\"token\":\"secret-value\",\"detail\":\"provider body\"}"#

    @Test func aiServiceErrorsDoNotExposeProviderResponseBodies() throws {
        let httpMessage = try #require(
            AIServiceError.httpError(503, Self.rawCanary).errorDescription
        )
        #expect(httpMessage.contains("503"))
        #expect(!httpMessage.contains(Self.rawCanary))
        #expect(!httpMessage.contains("secret-value"))
        #expect(!httpMessage.contains("provider body"))

        let unavailableMessage = try #require(
            AIServiceError.noProvider(Self.rawCanary).errorDescription
        )
        #expect(!unavailableMessage.contains(Self.rawCanary))
        #expect(!unavailableMessage.contains("secret-value"))

        let appleMessage = try #require(
            AIServiceError.onDeviceModelFailed.errorDescription
        )
        #expect(!appleMessage.contains(Self.rawCanary))

        let mappedNativeError = AppleFoundationModelService.userVisibleError(
            from: NSError(
                domain: Self.rawCanary,
                code: 77,
                userInfo: [NSLocalizedDescriptionKey: Self.rawCanary]
            )
        )
        let mappedMessage = try #require(mappedNativeError.localizedDescription as String?)
        #expect(!mappedMessage.contains(Self.rawCanary))
        #expect(mappedMessage == appleMessage)
    }

    @Test func appleChatStreamExitMapsNativeErrorsBeforeTheyReachConsumers() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            AppleFoundationModelService.finishChatStream(
                continuation,
                throwing: NSError(
                    domain: Self.rawCanary,
                    code: 78,
                    userInfo: [NSLocalizedDescriptionKey: Self.rawCanary]
                )
            )
        }

        do {
            for try await _ in stream {
                Issue.record("Native-error stream unexpectedly emitted content")
            }
            Issue.record("Native-error stream unexpectedly finished successfully")
        } catch {
            let message = error.localizedDescription
            #expect(!message.contains(Self.rawCanary))
            #expect(!message.contains("secret-value"))
            #expect(message == AIServiceError.onDeviceModelFailed.localizedDescription)
        }

        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Cadenza/Services/AI/AppleFoundationModelService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Self.finishChatStream(continuation, throwing: error)"))
        #expect(!source.contains("continuation.finish(throwing: error)"))
    }

    @Test func aiTransportErrorsDoNotExposeImplementationCanaries() throws {
        let cases: [(AITransportError, String)] = [
            (.unsafeEndpoint, "The AI provider endpoint is not permitted"),
            (.requestFailed, "The AI provider request failed"),
            (.bufferedResponseTooLarge, "The AI provider response exceeded the allowed size"),
        ]

        for (error, legacyCanary) in cases {
            let message = try #require(error.errorDescription)
            #expect(message != legacyCanary)
            #expect(!message.contains("not permitted"))
            #expect(!message.contains("exceeded the allowed size"))
        }
    }

    @Test func oauthErrorsDoNotExposeTokenEndpointBodies() throws {
        let message = try #require(
            OAuthError.tokenExchangeFailed(Self.rawCanary).errorDescription
        )
        #expect(!message.contains(Self.rawCanary))
        #expect(!message.contains("secret-value"))
        #expect(!message.contains("provider body"))
    }

    @Test func transcriptionErrorsDoNotExposeProviderOrImplementationDetails() throws {
        let apiMessage = try #require(
            TranscriptionError.apiError(Self.rawCanary).errorDescription
        )
        let unsupportedMessage = try #require(
            TranscriptionError.notSupported(Self.rawCanary).errorDescription
        )
        for message in [apiMessage, unsupportedMessage] {
            #expect(!message.contains(Self.rawCanary))
            #expect(!message.contains("secret-value"))
            #expect(!message.contains("provider body"))
        }


        let mapped = TranscriptionError.userVisible(
            from: NSError(
                domain: Self.rawCanary,
                code: 88,
                userInfo: [NSLocalizedDescriptionKey: Self.rawCanary]
            )
        )
        let mappedMessage = try #require(mapped.errorDescription)
        #expect(!mappedMessage.contains(Self.rawCanary))
    }

    @Test func exportErrorsDoNotExposeRawCallerDetails() throws {
        let message = try #require(ExportError.unexpected(Self.rawCanary).errorDescription)
        #expect(!message.contains(Self.rawCanary))
        #expect(!message.contains("secret-value"))
        #expect(!message.contains("provider body"))

        let generic = ExportUserMessage.message(
            for: NSError(
                domain: Self.rawCanary,
                code: 99,
                userInfo: [NSLocalizedDescriptionKey: Self.rawCanary]
            )
        )
        #expect(!generic.contains(Self.rawCanary))

        let backend = CadenzaAPIError.backend(
            envelope: BackendErrorEnvelope(
                code: "rate_limited",
                message: Self.rawCanary,
                integration: nil,
                upstreamStatus: 503,
                retryAfter: 60
            ),
            status: 429
        )
        let backendMessage = try #require(backend.errorDescription)
        #expect(!backendMessage.contains(Self.rawCanary))
        #expect(!backendMessage.contains("secret-value"))
    }

    @Test func mcpAndCalendarPresentationErrorsNeverExposeRawDiagnostics() {
        let connectorErrors: [MCPClientConnector.ConnectorError] = [
            .cliFailed(Self.rawCanary),
            .configNotAnObject(Self.rawCanary),
            .configUnreadable(Self.rawCanary),
            .configUnrecognized(Self.rawCanary),
            .configurationFailed(Self.rawCanary),
        ]
        for error in connectorErrors {
            let message = error.localizedMessage()
            #expect(!message.contains(Self.rawCanary))
            #expect(!message.contains("secret-value"))
        }

        let arbitrary = NSError(
            domain: Self.rawCanary,
            code: 100,
            userInfo: [NSLocalizedDescriptionKey: Self.rawCanary]
        )
        #expect(!MCPClientConnector.userVisibleMessage(for: arbitrary).contains(Self.rawCanary))
        #expect(!CalendarRefreshErrorPresentation.message(for: arbitrary).contains(Self.rawCanary))
    }

    @Test func everyServiceErrorResolvesThroughChineseRuntimeResources() {
        let zh = Locale(identifier: "zh-Hans")
        let messages = [
            AIServiceError.invalidResponse.localizedMessage(locale: zh),
            AIServiceError.httpError(503, Self.rawCanary).localizedMessage(locale: zh),
            AIServiceError.noAPIKey.localizedMessage(locale: zh),
            AIServiceError.noProvider(Self.rawCanary).localizedMessage(locale: zh),
            AIServiceError.onDeviceModelFailed.localizedMessage(locale: zh),
            AITransportError.unsafeEndpoint.localizedMessage(locale: zh),
            AITransportError.responseOriginMismatch.localizedMessage(locale: zh),
            AITransportError.invalidHTTPResponse.localizedMessage(locale: zh),
            AITransportError.bufferedResponseTooLarge.localizedMessage(locale: zh),
            AITransportError.streamResponseTooLarge.localizedMessage(locale: zh),
            AITransportError.streamLineTooLarge.localizedMessage(locale: zh),
            AITransportError.streamFrameLimitExceeded.localizedMessage(locale: zh),
            AITransportError.streamDeadlineExceeded.localizedMessage(locale: zh),
            AITransportError.invalidStreamEncoding.localizedMessage(locale: zh),
            AITransportError.modelListItemLimitExceeded.localizedMessage(locale: zh),
            AITransportError.invalidModelIdentifier.localizedMessage(locale: zh),
            AITransportError.requestFailed.localizedMessage(locale: zh),
            OAuthError.authorizationDenied.localizedMessage(locale: zh),
            OAuthError.tokenExchangeFailed(Self.rawCanary).localizedMessage(locale: zh),
            OAuthError.refreshFailed.localizedMessage(locale: zh),
            OAuthError.noRefreshToken.localizedMessage(locale: zh),
            OAuthError.invalidResponse.localizedMessage(locale: zh),
            OAuthError.callbackTimeout.localizedMessage(locale: zh),
            OAuthError.callbackInProgress.localizedMessage(locale: zh),
            OAuthError.stateMismatch.localizedMessage(locale: zh),
            OAuthError.networkFailure.localizedMessage(locale: zh),
            TranscriptionError.apiError(Self.rawCanary).localizedMessage(locale: zh),
            TranscriptionError.notSupported(Self.rawCanary).localizedMessage(locale: zh),
            TranscriptionError.fileNotFound.localizedMessage(locale: zh),
            TranscriptionError.fileTooLarge.localizedMessage(locale: zh),
            TranscriptionError.permissionDenied.localizedMessage(locale: zh),
            ExportError.recordingNotFound.localizedMessage(locale: zh),
            ExportError.notionDatabaseNotSelected.localizedMessage(locale: zh),
            ExportError.craftNotInstalled.localizedMessage(locale: zh),
            ExportError.craftLinkCreationFailed.localizedMessage(locale: zh),
            ExportError.craftURLHandlerUnavailable.localizedMessage(locale: zh),
            ExportError.craftOpenFailed.localizedMessage(locale: zh),
            ExportError.unexpected(Self.rawCanary).localizedMessage(locale: zh),
            ExportUserMessage.message(
                for: NSError(domain: Self.rawCanary, code: 101),
                locale: zh
            ),
            CadenzaAPIError.backend(
                envelope: BackendErrorEnvelope(
                    code: "rate_limited",
                    message: Self.rawCanary,
                    integration: nil,
                    upstreamStatus: nil,
                    retryAfter: nil
                ),
                status: 429
            ).localizedMessage(locale: zh),
            MCPServer.listenerFailureMessage(locale: zh),
            MCPClientConnector.ConnectorError.cliFailed(Self.rawCanary)
                .localizedMessage(locale: zh),
            CalendarRefreshErrorPresentation.message(
                for: NSError(domain: Self.rawCanary, code: 102),
                locale: zh
            ),
            WhisperModelManager.downloadFailureMessage(locale: zh),
        ]

        for message in messages {
            #expect(!message.isEmpty)
            #expect(
                message.unicodeScalars.contains { scalar in
                    (0x3400...0x9FFF).contains(Int(scalar.value))
                },
                "expected a zh-Hans runtime translation, got: \(message)"
            )
            #expect(!message.contains(Self.rawCanary))
        }
    }

    @Test func oauthCallbackPageIsLocalizedAndEscapesHTML() {
        let zh = Locale(identifier: "zh-Hans")
        let success = OAuthCallbackPage.html(for: .success, locale: zh)
        let failure = OAuthCallbackPage.html(for: .failure, locale: zh)

        #expect(success.contains("授权成功"))
        #expect(success.contains("关闭此窗口"))
        #expect(!success.contains("Authorization successful"))
        #expect(failure.contains("登录失败"))
        #expect(failure.contains("安全校验未通过"))
        #expect(!failure.contains("Sign-in failed"))

        let unsafe = OAuthCallbackPage.render(
            title: #"<script>alert(\"title\")</script>"#,
            message: #"<&'\"message\">"#
        )
        #expect(!unsafe.contains("<script>"))
        #expect(unsafe.contains("&lt;script&gt;"))
        #expect(unsafe.contains("&amp;"))
        #expect(unsafe.contains("&#39;"))
        #expect(unsafe.contains("&quot;"))
    }

    @Test func everyServiceErrorResourceHasAllSupportedLocales() throws {
        let catalog = try Self.loadCatalogStrings()
        let requiredLocales = ["de", "es", "fr", "ja", "ko", "zh-Hans"]
        let keys = [
            "The AI provider returned an invalid response. Try again or choose another provider in Settings.",
            "The AI provider request failed (HTTP %lld). Check your API key, provider status, and network connection.",
            "No AI provider configured. Add an API key in Settings.",
            "The selected AI provider is unavailable on this Mac. Choose another provider in Settings.",
            "Apple Intelligence couldn't complete the request. Try again or choose another AI provider in Settings.",
            "The AI provider connection was blocked for security. Check the provider endpoint in Settings.",
            "The AI provider response was too large to process. Try again with less content or choose another provider.",
            "The AI provider took too long to respond. Check your network connection and try again.",
            "The AI provider request failed. Check your API key, provider status, and network connection.",
            "Authorization was denied.",
            "Sign-in failed.",
            "Your session expired — please sign in again.",
            "Sign-in completed with an invalid response.",
            "Sign-in timed out.",
            "Another sign-in is already in progress.",
            "Security check failed. Please try again.",
            "Network error — please check your connection.",
            "Authorization successful!",
            "You can close this window and return to Cadenza.",
            "Transcription failed. Check the selected provider settings and network connection, then try again.",
            "The selected transcription operation isn't supported. Choose another transcription provider in Settings.",
            "The audio file for this recording could not be found.",
            "The audio file is too large for the selected transcription provider. Use a shorter recording or choose another provider.",
            "Speech Recognition access is required. Enable Cadenza in System Settings → Privacy & Security → Speech Recognition.",
            "Recording not found (possibly deleted)",
            "Select a Notion database first",
            "Craft is not installed. Install Craft, then try again.",
            "Craft couldn't open the document. Make sure Craft is installed, then try again.",
            "Export failed. Check the destination settings and try again.",
            "Model download failed. Check your network connection and try again.",
            "MCP server couldn't start. Check whether the selected port is available, then try again.",
            "Automatic setup couldn't update this client's configuration safely. Copy the manual configuration below instead.",
            "Calendar refresh failed. Check your network connection and reconnect in Settings if the problem continues.",
        ]

        for key in keys {
            let entry = try #require(catalog[key] as? [String: Any], "missing key: \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "missing localizations: \(key)"
            )
            for locale in requiredLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any],
                    "missing \(locale): \(key)"
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any],
                    "missing string unit for \(locale): \(key)"
                )
                let value = try #require(
                    unit["value"] as? String,
                    "missing value for \(locale): \(key)"
                )
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private static func loadCatalogStrings() throws -> [String: Any] {
        let catalogURL = repositoryRoot.appendingPathComponent(
            "Cadenza/Resources/Localizable.xcstrings"
        )
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
                as? [String: Any]
        )
        return try #require(root["strings"] as? [String: Any])
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
