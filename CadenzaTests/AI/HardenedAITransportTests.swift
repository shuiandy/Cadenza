import Foundation
import Synchronization
import Testing

@testable import Cadenza

@Suite("Hardened AI Transport", .serialized)
struct HardenedAITransportTests {
    @Test(arguments: [
        "http://api.openai.com/v1/chat/completions",
        "https://localhost/v1/chat/completions",
        "https://sub.localhost/v1/chat/completions",
        "https://127.0.0.1/v1/chat/completions",
        "https://127.1/v1/chat/completions",
        "https://0177.0.0.1/v1/chat/completions",
        "https://0x7f.0.0.1/v1/chat/completions",
        "https://2130706433/v1/chat/completions",
        "https://[::1]/v1/chat/completions",
        "https://10.0.0.1/v1/chat/completions",
        "https://user:password@api.openai.com/v1/chat/completions",
        "https://api.openai.com:8443/v1/chat/completions",
    ])
    func unsafeInitialEndpointsAreRejected(_ rawURL: String) throws {
        let url = try #require(URL(string: rawURL))

        #expect(throws: AITransportError.self) {
            try AIEndpointPolicy.validate(url, provider: .openai)
        }
    }

    @Test func miniMaxMustUseOfficialOrigin() throws {
        let impostor = try #require(URL(string: "https://example.com/v1/chat/completions"))
        let official = try #require(URL(string: "https://api.minimax.io/v1/chat/completions"))

        #expect(throws: AITransportError.self) {
            try AIEndpointPolicy.validate(impostor, provider: .minimax)
        }
        #expect(throws: Never.self) {
            try AIEndpointPolicy.validate(official, provider: .minimax)
        }
    }

    @Test(arguments: [302, 307, 308])
    func redirectIsRejectedBeforeTargetReceivesRequest(statusCode: Int) async throws {
        AITransportTestURLProtocol.reset()
        let transport = makeTransport()
        let url = try #require(URL(string: "https://api.openai.com/redirect?status=\(statusCode)"))

        await #expect(throws: Error.self) {
            _ = try await transport.data(
                for: URLRequest(url: url),
                provider: .openai,
                redacting: ["openai-secret"]
            )
        }

        #expect(AITransportTestURLProtocol.requestCount(forHost: "redirect-target.example") == 0)
    }

    @Test func claudeAPIKeyIsNotForwardedAcrossRedirect() async throws {
        AITransportTestURLProtocol.reset()
        let transport = makeTransport()
        let key = "claude-super-secret"
        let url = try #require(URL(string: "https://api.anthropic.com/redirect?status=307"))
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")

        do {
            _ = try await transport.data(for: request, provider: .claude, redacting: [key])
            Issue.record("expected redirect to be rejected")
        } catch {
            #expect(!error.localizedDescription.contains(key))
        }

        #expect(AITransportTestURLProtocol.requestCount(forHost: "redirect-target.example") == 0)
        #expect(AITransportTestURLProtocol.secretObservedByTarget == nil)
    }

    @Test func finalResponseOriginMustMatchInitialOrigin() async throws {
        let transport = makeTransport()
        let url = try #require(URL(string: "https://api.openai.com/origin-mismatch"))

        await #expect(throws: AITransportError.self) {
            _ = try await transport.data(for: URLRequest(url: url), provider: .openai)
        }
    }

    @Test func providerErrorBodyIsBoundedAndSecretRedacted() async throws {
        let transport = makeTransport()
        let secret = "claude-error-secret"
        let url = try #require(URL(string: "https://api.anthropic.com/error-echo"))
        var request = URLRequest(url: url)
        request.setValue(secret, forHTTPHeaderField: "x-api-key")

        do {
            _ = try await transport.data(for: request, provider: .claude, redacting: [secret])
            Issue.record("expected provider error")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(error.localizedDescription.utf8.count < 512)
        }
    }

    @Test func underlyingNetworkErrorCannotExposeSecretURL() async throws {
        let transport = makeTransport()
        let secret = "gemini-network-secret"
        let url = try #require(URL(string: "https://generativelanguage.googleapis.com/network-error"))
        var request = URLRequest(url: url)
        request.setValue(secret, forHTTPHeaderField: "x-goog-api-key")

        do {
            _ = try await transport.data(
                for: request,
                provider: .gemini,
                redacting: [secret]
            )
            Issue.record("expected network error")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test func bufferedResponseRejectsOversizedBody() async throws {
        let limits = testLimits(maxBufferedResponseBytes: 32)
        let transport = makeTransport(limits: limits)
        let url = try #require(URL(string: "https://api.openai.com/buffered-oversize"))

        await #expect(throws: AITransportError.self) {
            _ = try await transport.data(for: URLRequest(url: url), provider: .openai)
        }
    }

    @Test func normalSSEFramesAreParsedWithoutFoundationLineBuffering() async throws {
        let transport = makeTransport()
        let url = try #require(URL(string: "https://api.openai.com/sse-normal"))
        var payloads: [String] = []

        for try await payload in transport.serverSentEvents(
            for: URLRequest(url: url),
            provider: .openai
        ) {
            payloads.append(payload)
        }

        #expect(payloads == ["{\"delta\":\"hello\"}", "[DONE]"])
    }

    @Test func SSERejectsOversizedLine() async throws {
        let limits = testLimits(maxSSELineBytes: 16)
        let transport = makeTransport(limits: limits)
        let url = try #require(URL(string: "https://api.openai.com/sse-line-oversize"))

        await #expect(throws: AITransportError.self) {
            for try await _ in transport.serverSentEvents(
                for: URLRequest(url: url),
                provider: .openai
            ) {}
        }
    }

    @Test func SSERejectsOversizedTotalBody() async throws {
        let limits = testLimits(maxSSETotalBytes: 40)
        let transport = makeTransport(limits: limits)
        let url = try #require(URL(string: "https://api.openai.com/sse-total-oversize"))

        await #expect(throws: AITransportError.self) {
            for try await _ in transport.serverSentEvents(
                for: URLRequest(url: url),
                provider: .openai
            ) {}
        }
    }

    @Test func SSERejectsTooManyFrames() async throws {
        let limits = testLimits(maxSSEFrameCount: 2)
        let transport = makeTransport(limits: limits)
        let url = try #require(URL(string: "https://api.openai.com/sse-frame-oversize"))

        await #expect(throws: AITransportError.self) {
            for try await _ in transport.serverSentEvents(
                for: URLRequest(url: url),
                provider: .openai
            ) {}
        }
    }

    @Test func SSEParserRejectsExpiredTotalDeadlineDeterministically() throws {
        let clock = ManualAITransportClock()
        var parser = BoundedSSEParser(
            limits: testLimits(maxStreamDuration: .seconds(5)),
            clock: clock.source
        )
        _ = try parser.consume(byte: UInt8(ascii: "d"))
        clock.advance(by: .seconds(6))

        #expect(throws: AITransportError.self) {
            try parser.consume(byte: UInt8(ascii: "a"))
        }
    }

    @Test(arguments: SummaryDetailLevel.allCases)
    func claudeSummaryBudgetReachesActualCompletionTransport(level: SummaryDetailLevel) async throws {
        AITransportTestURLProtocol.reset()
        let service: any AIServiceProtocol = ClaudeService(apiKey: "fixture-key", transport: makeTransport())
        for try await _ in service.streamSummaryCompletion(systemPrompt: "fixture", userMessage: "fictional meeting", model: "claude-sonnet-4-6", detailLevel: level) {}
        let data = try #require(AITransportTestURLProtocol.capturedRequest(forHost: "api.anthropic.com")?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected: Int = level == .highlights ? 4096 : level == .detailed ? 8192 : 16384
        #expect(body["max_tokens"] as? Int == expected)
        for try await _ in service.streamChat(systemPrompt: "fixture", userMessage: "hello", model: "claude-sonnet-4-6") {}
        let chat = try #require(AITransportTestURLProtocol.capturedRequest(forHost: "api.anthropic.com")?.body)
        #expect((try JSONSerialization.jsonObject(with: chat) as? [String: Any])?["max_tokens"] as? Int == 4096)
    }

    @Test(arguments: ["max_tokens", "model_context_window_exceeded", "refusal", "missing_reason", "missing_stop"])
    func claudeRejectsIncompleteBufferedAndStreamingResponses(reason: String) async throws {
        AITransportTestURLProtocol.reset(claudeTermination: reason)
        let service = ClaudeService(apiKey: "fixture-key", transport: makeTransport())
        await #expect(throws: AIServiceError.self) {
            _ = try await service.summarize(transcript: "fictional", language: "en", model: "claude-sonnet-4-6", knownTags: [])
        }
        await #expect(throws: AIServiceError.self) {
            for try await _ in service.streamSummaryCompletion(systemPrompt: "fixture", userMessage: "fictional", model: "claude-sonnet-4-6", detailLevel: .fullBreakdown) {}
        }
    }

    @Test func claudeUsageDeltaPreservesTerminationAndChatAllowsTruncation() async throws {
        AITransportTestURLProtocol.reset(claudeTermination: "usage_after_stop")
        let service = ClaudeService(apiKey: "fixture-key", transport: makeTransport())
        for try await _ in service.streamSummaryCompletion(systemPrompt: "fixture", userMessage: "fictional", model: nil, detailLevel: .detailed) {}
        AITransportTestURLProtocol.reset(claudeTermination: "max_tokens")
        var text = ""
        for try await chunk in service.streamChat(systemPrompt: "fixture", userMessage: "fictional", model: nil) { text += chunk }
        #expect(text == "claude")
    }

    @Test(arguments: ["length", "missing_reason"])
    func otherProvidersRejectIncompleteSummaries(reason: String) async throws {
        AITransportTestURLProtocol.reset(summaryTermination: reason)
        let services: [any AIServiceProtocol] = [
            OpenAIService(apiKey: "fixture-key", transport: makeTransport()),
            GeminiService(apiKey: "fixture-key", transport: makeTransport())
        ]
        for service in services {
            await #expect(throws: AIServiceError.self) {
                _ = try await service.summarize(transcript: "fictional", language: "en", model: nil, knownTags: [])
            }
            await #expect(throws: AIServiceError.self) {
                for try await _ in service.streamSummaryCompletion(systemPrompt: "fixture", userMessage: "fictional", model: nil, detailLevel: .detailed) {}
            }
            var chat = ""
            for try await part in service.streamChat(systemPrompt: "fixture", userMessage: "fictional", model: nil) { chat += part }
            #expect(!chat.isEmpty)
        }
    }

    @Test func claudeUnknownModelRetainsConservativeBudget() {
        #expect(ClaudeService.summaryOutputBudget(model: "unknown", detailLevel: .fullBreakdown) == 4096)
        #expect(ClaudeService.summaryOutputBudget(model: "claude-haiku-4-5-20251001", detailLevel: .fullBreakdown) == 16384)
    }

    @Test(arguments: SummaryDetailLevel.allCases)
    func allProviderBufferedSummariesUseSelectedDepth(level: SummaryDetailLevel) async throws {
        AITransportTestURLProtocol.reset()
        let transport = makeTransport()
        let services: [AIServiceProtocol] = [
            OpenAIService(apiKey: "openai-key", transport: transport),
            ClaudeService(apiKey: "claude-key", transport: transport),
            GeminiService(apiKey: "gemini-key", transport: transport),
        ]

        for service in services {
            let result = try await service.summarize(
                transcript: "hello",
                language: "en",
                model: nil,
                jobTitle: nil,
                meetingType: nil,
                meetingTitle: nil,
                knownTags: [], detailLevel: level
            )
            #expect(result.title == "Transport protected")
            let host = service.provider == .openai ? "api.openai.com"
                : service.provider == .claude ? "api.anthropic.com" : "generativelanguage.googleapis.com"
            let body = try #require(AITransportTestURLProtocol.capturedRequest(forHost: host)?.body)
            #expect(String(decoding: body, as: UTF8.self).contains(level.promptGuidance))
        }
    }

    @Test func allProviderChatStreamsUseBoundedSSETransport() async throws {
        let transport = makeTransport()
        let services: [(AIServiceProtocol, String)] = [
            (OpenAIService(apiKey: "openai-key", transport: transport), "openai"),
            (ClaudeService(apiKey: "claude-key", transport: transport), "claude"),
            (GeminiService(apiKey: "gemini-key", transport: transport), "gemini"),
        ]

        for (service, expected) in services {
            var response = ""
            for try await chunk in service.streamChat(
                systemPrompt: "system",
                userMessage: "hello",
                model: nil
            ) {
                response += chunk
            }
            #expect(response == expected)
        }
    }

    @Test func modelListUsesInjectedBoundedTransport() async throws {
        let service = AIChatModelListService(transport: makeTransport())

        let presets = try await service.fetchPresets(for: .openai, apiKey: "openai-key")

        #expect(presets.map(\.modelID) == ["gpt-transport-model"])
    }

    @Test func settingsCredentialValidationUsesProviderModelRequestBuilder() async throws {
        let cases: [(AIProvider, String, String)] = [
            (.openai, "openai-key", "api.openai.com"),
            (.claude, "claude-key", "api.anthropic.com"),
            (.gemini, "gemini-key", "generativelanguage.googleapis.com"),
            (.minimax, "minimax-key", "api.minimax.io"),
        ]

        for (provider, apiKey, expectedHost) in cases {
            AITransportTestURLProtocol.reset()
            let validator = AIProviderCredentialValidator(
                modelListService: AIChatModelListService(transport: makeTransport())
            )

            let validationError = await validator.validateAPIKey(apiKey, provider: provider)
            let request = try #require(
                AITransportTestURLProtocol.capturedRequest(forHost: expectedHost)
            )

            #expect(validationError == nil)
            #expect(request.urlString.contains(apiKey) == false)
            switch provider {
            case .openai, .minimax:
                #expect(request.authorization == "Bearer \(apiKey)")
            case .claude:
                #expect(request.apiKey == apiKey)
                #expect(request.anthropicVersion == "2023-06-01")
            case .gemini:
                #expect(request.apiKey == apiKey)
                #expect(request.urlString == "https://generativelanguage.googleapis.com/v1beta/models")
            case .apple, .whisperLocal:
                Issue.record("unexpected local provider")
            }
        }
    }

    @Test func settingsCredentialValidationRejectsRedirectBeforeTargetReceivesKey() async throws {
        AITransportTestURLProtocol.reset(modelListMode: .redirect)
        let validator = AIProviderCredentialValidator(
            modelListService: AIChatModelListService(transport: makeTransport())
        )

        let validationError = await validator.validateAPIKey(
            "openai-settings-secret",
            provider: .openai
        )

        #expect(validationError != nil)
        #expect(AITransportTestURLProtocol.requestCount(forHost: "redirect-target.example") == 0)
    }

    @Test func settingsCredentialValidationRejectsOversizedResponse() async throws {
        AITransportTestURLProtocol.reset(modelListMode: .oversized)
        let limits = testLimits(maxBufferedResponseBytes: 32)
        let validator = AIProviderCredentialValidator(
            modelListService: AIChatModelListService(
                transport: makeTransport(limits: limits)
            )
        )

        let validationError = await validator.validateAPIKey(
            "openai-settings-secret",
            provider: .openai
        )

        #expect(validationError != nil)
    }

    @Test func settingsCredentialValidationNeverReturnsProviderEchoedSecret() async throws {
        AITransportTestURLProtocol.reset(modelListMode: .errorEcho)
        let secret = "claude-settings-secret"
        let validator = AIProviderCredentialValidator(
            modelListService: AIChatModelListService(transport: makeTransport())
        )

        let validationError = await validator.validateAPIKey(secret, provider: .claude)

        #expect(validationError != nil)
        #expect(validationError?.contains(secret) == false)
    }

    private func makeTransport(
        limits: AITransportLimits? = nil
    ) -> HardenedAITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AITransportTestURLProtocol.self]
        return HardenedAITransport(
            configuration: configuration,
            limits: limits ?? testLimits()
        )
    }

    private func testLimits(
        maxBufferedResponseBytes: Int = 1_024,
        maxSSETotalBytes: Int = 1_024,
        maxSSELineBytes: Int = 256,
        maxSSEFrameCount: Int = 16,
        maxStreamDuration: Duration = .seconds(30)
    ) -> AITransportLimits {
        AITransportLimits(
            maxBufferedResponseBytes: maxBufferedResponseBytes,
            maxErrorResponseBytes: 128,
            maxSSETotalBytes: maxSSETotalBytes,
            maxSSELineBytes: maxSSELineBytes,
            maxSSEFrameCount: maxSSEFrameCount,
            maxStreamDuration: maxStreamDuration
        )
    }
}

private final class ManualAITransportClock: Sendable {
    private let elapsed = Mutex<Duration>(.zero)

    var source: AITransportClock {
        AITransportClock(now: { self.elapsed.withLock { $0 } })
    }

    func advance(by duration: Duration) {
        elapsed.withLock { $0 += duration }
    }
}

private final class AITransportTestURLProtocol: URLProtocol {
    enum ModelListMode: Sendable {
        case success
        case redirect
        case oversized
        case errorEcho
    }

    struct CapturedRequest: Sendable {
        let urlString: String
        let authorization: String?
        let apiKey: String?
        let anthropicVersion: String?
        let body: Data?
    }

    private struct State: Sendable {
        var requestCountByHost: [String: Int] = [:]
        var secretObservedByTarget: String?
        var modelListMode: ModelListMode = .success
        var claudeTermination = "end_turn"
        var summaryTermination = "stop"
        var capturedRequestsByHost: [String: CapturedRequest] = [:]
    }

    private static let state = Mutex(State())

    static var secretObservedByTarget: String? {
        state.withLock { $0.secretObservedByTarget }
    }

    static func reset(modelListMode: ModelListMode = .success, claudeTermination: String = "end_turn", summaryTermination: String = "stop") {
        state.withLock { $0 = State(modelListMode: modelListMode, claudeTermination: claudeTermination, summaryTermination: summaryTermination) }
    }

    static func requestCount(forHost host: String) -> Int {
        state.withLock { $0.requestCountByHost[host, default: 0] }
    }

    static func capturedRequest(forHost host: String) -> CapturedRequest? {
        state.withLock { $0.capturedRequestsByHost[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // URLSession hands URLProtocol buffered POST bodies as an input stream.
        // Read it once for both request assertions and the fixture response.
        let bodyData = capturedBody()

        Self.state.withLock { state in
            state.requestCountByHost[host, default: 0] += 1
            state.capturedRequestsByHost[host] = CapturedRequest(
                urlString: url.absoluteString,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                apiKey: request.value(forHTTPHeaderField: "x-api-key")
                    ?? request.value(forHTTPHeaderField: "x-goog-api-key"),
                anthropicVersion: request.value(forHTTPHeaderField: "anthropic-version"),
                body: bodyData
            )
            if host == "redirect-target.example" {
                state.secretObservedByTarget = request.value(forHTTPHeaderField: "x-api-key")
            }
        }

        switch url.path {
        case "/redirect":
            sendRedirect(from: url)
        case "/buffered-oversize":
            send(status: 200, data: Data(repeating: 0x61, count: 64), url: url)
        case "/origin-mismatch":
            send(
                status: 200,
                data: Data("{}".utf8),
                url: URL(string: "https://different-origin.example/response")!
            )
        case "/error-echo":
            let secret = request.value(forHTTPHeaderField: "x-api-key") ?? "missing"
            send(
                status: 401,
                data: Data(String(repeating: "provider echoed \(secret) ", count: 32).utf8),
                url: url
            )
        case "/network-error":
            let secret = request.value(forHTTPHeaderField: "x-goog-api-key") ?? "missing"
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "AITransportTest",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "failed URL contains \(secret)"]
                )
            )
        case "/sse-normal":
            send(status: 200, data: Data("data: {\"delta\":\"hello\"}\n\ndata: [DONE]\n\n".utf8), url: url)
        case "/sse-line-oversize":
            send(status: 200, data: Data("data: \(String(repeating: "x", count: 64))\n\n".utf8), url: url)
        case "/sse-total-oversize":
            send(status: 200, data: Data(String(repeating: ": heartbeat\n", count: 8).utf8), url: url)
        case "/sse-frame-oversize":
            send(status: 200, data: Data("data: one\n\ndata: two\n\ndata: three\n\n".utf8), url: url)
        case "/v1/chat/completions":
            sendProviderResponse(provider: "openai", url: url, bodyData: bodyData)
        case "/v1/messages":
            sendProviderResponse(provider: "claude", url: url, bodyData: bodyData)
        case "/v1/models":
            sendModelListResponse(url: url)
        case "/v1beta/models":
            sendModelListResponse(url: url)
        case let path where path.hasSuffix(":generateContent"):
            sendProviderResponse(provider: "gemini", url: url, bodyData: bodyData)
        case let path where path.hasSuffix(":streamGenerateContent"):
            sendProviderResponse(provider: "gemini", url: url, bodyData: bodyData, streaming: true)
        default:
            send(status: 200, data: Data("{}".utf8), url: url)
        }
    }

    override func stopLoading() {}

    private func capturedBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func sendRedirect(from url: URL) {
        let status = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "status" })?
            .value
            .flatMap(Int.init) ?? 302
        let target = URL(string: "https://redirect-target.example/collect")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func send(status: Int, data: Data, url: URL) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func sendModelListResponse(url: URL) {
        let mode = Self.state.withLock { $0.modelListMode }
        switch mode {
        case .success:
            let data: Data
            if url.host == "generativelanguage.googleapis.com" {
                data = Data("{\"models\":[]}".utf8)
            } else {
                data = Data("{\"data\":[{\"id\":\"gpt-transport-model\"}]}".utf8)
            }
            send(status: 200, data: data, url: url)
        case .redirect:
            sendRedirect(from: url)
        case .oversized:
            send(status: 200, data: Data(repeating: 0x61, count: 64), url: url)
        case .errorEcho:
            let secret = request.value(forHTTPHeaderField: "x-api-key")
                ?? request.value(forHTTPHeaderField: "Authorization")
                ?? "missing"
            send(status: 401, data: Data("provider echoed \(secret)".utf8), url: url)
        }
    }

    private func sendProviderResponse(
        provider: String,
        url: URL,
        bodyData: Data?,
        streaming explicitStreaming: Bool? = nil
    ) {
        let bodyObject = bodyData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let streaming = explicitStreaming
            ?? (request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            || (bodyObject?["stream"] as? Bool == true)
        if streaming {
            let payload: String
            switch provider {
            case "claude":
                let reason = Self.state.withLock { $0.claudeTermination }
                var frames = ["data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"claude\"}}"]
                if reason != "missing_reason" {
                    let stop = ["missing_stop", "usage_after_stop"].contains(reason) ? "end_turn" : reason
                    frames.append("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stop)\"}}")
                }
                if reason == "usage_after_stop" { frames.append(#"data: {"type":"message_delta","delta":{},"usage":{"output_tokens":3}}"#) }
                if reason != "missing_stop" { frames.append("data: {\"type\":\"message_stop\"}") }
                payload = frames.joined(separator: "\n\n") + "\n\n"
            case "gemini":
                let reason = Self.state.withLock { $0.summaryTermination }
                let terminal = reason == "missing_reason" ? "" : ",\"finishReason\":\"\(reason == "stop" ? "STOP" : "MAX_TOKENS")\""
                payload = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"gemini\"}]}\(terminal)}]}\n\n"
            default:
                let reason = Self.state.withLock { $0.summaryTermination }
                let terminal = reason == "missing_reason" ? "" : ",\"finish_reason\":\"\(reason)\""
                payload = "data: {\"choices\":[{\"delta\":{\"content\":\"openai\"}\(terminal)}]}\n\ndata: [DONE]\n\n"
            }
            send(status: 200, data: Data(payload.utf8), url: url)
            return
        }

        let summary = "{\"title\":\"Transport protected\",\"overview\":\"ok\"}"
        let object: [String: Any]
        switch provider {
        case "claude":
            object = ["content": [["type": "text", "text": summary]], "stop_reason": Self.state.withLock { $0.claudeTermination }]
        case "gemini":
            let reason = Self.state.withLock { $0.summaryTermination }
            object = ["candidates": [["content": ["parts": [["text": summary]]], "finishReason": reason == "stop" ? "STOP" : reason]]]
        default:
            object = ["choices": [["message": ["content": summary], "finish_reason": Self.state.withLock { $0.summaryTermination }]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        send(status: 200, data: data, url: url)
    }
}
