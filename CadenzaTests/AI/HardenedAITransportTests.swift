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

    @Test func allProviderBufferedSummariesUseInjectedHardenedTransport() async throws {
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
                knownTags: []
            )
            #expect(result.title == "Transport protected")
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
    }

    private struct State: Sendable {
        var requestCountByHost: [String: Int] = [:]
        var secretObservedByTarget: String?
        var modelListMode: ModelListMode = .success
        var capturedRequestsByHost: [String: CapturedRequest] = [:]
    }

    private static let state = Mutex(State())

    static var secretObservedByTarget: String? {
        state.withLock { $0.secretObservedByTarget }
    }

    static func reset(modelListMode: ModelListMode = .success) {
        state.withLock { $0 = State(modelListMode: modelListMode) }
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

        Self.state.withLock { state in
            state.requestCountByHost[host, default: 0] += 1
            state.capturedRequestsByHost[host] = CapturedRequest(
                urlString: url.absoluteString,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                apiKey: request.value(forHTTPHeaderField: "x-api-key")
                    ?? request.value(forHTTPHeaderField: "x-goog-api-key"),
                anthropicVersion: request.value(forHTTPHeaderField: "anthropic-version")
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
            sendProviderResponse(provider: "openai", url: url)
        case "/v1/messages":
            sendProviderResponse(provider: "claude", url: url)
        case "/v1/models":
            sendModelListResponse(url: url)
        case "/v1beta/models":
            sendModelListResponse(url: url)
        case let path where path.hasSuffix(":generateContent"):
            sendProviderResponse(provider: "gemini", url: url)
        case let path where path.hasSuffix(":streamGenerateContent"):
            sendProviderResponse(provider: "gemini", url: url, streaming: true)
        default:
            send(status: 200, data: Data("{}".utf8), url: url)
        }
    }

    override func stopLoading() {}

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
        streaming explicitStreaming: Bool? = nil
    ) {
        let bodyObject = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let streaming = explicitStreaming
            ?? (request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            || (bodyObject?["stream"] as? Bool == true)
        if streaming {
            let payload: String
            switch provider {
            case "claude":
                payload = """
                data: {"type":"content_block_delta","delta":{"text":"claude"}}

                data: {"type":"message_stop"}

                """
            case "gemini":
                payload = """
                data: {"candidates":[{"content":{"parts":[{"text":"gemini"}]}}]}

                """
            default:
                payload = """
                data: {"choices":[{"delta":{"content":"openai"}}]}

                data: [DONE]

                """
            }
            send(status: 200, data: Data(payload.utf8), url: url)
            return
        }

        let summary = "{\"title\":\"Transport protected\",\"overview\":\"ok\"}"
        let object: [String: Any]
        switch provider {
        case "claude":
            object = ["content": [["type": "text", "text": summary]]]
        case "gemini":
            object = ["candidates": [["content": ["parts": [["text": summary]]]]]]
        default:
            object = ["choices": [["message": ["content": summary]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        send(status: 200, data: data, url: url)
    }
}
