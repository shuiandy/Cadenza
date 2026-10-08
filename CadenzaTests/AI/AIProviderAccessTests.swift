import Foundation
import os
import Synchronization
import Testing

@testable import Cadenza

/// A scripted network for requests built from `AIProviderAccess`. Each test
/// installs a responder; every request is captured with its headers and body.
final class AIAccessStubURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data("{}".utf8)
    }

    struct Captured: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private struct State: Sendable {
        var respond: @Sendable (URLRequest) -> Response = { _ in Response() }
        var captured: [Captured] = []
    }

    private static let state = Mutex(State())

    static func install(_ respond: @escaping @Sendable (URLRequest) -> Response) {
        state.withLock { $0 = State(respond: respond) }
    }

    static var captured: [Captured] {
        state.withLock { $0.captured }
    }

    static func transport(limits: AITransportLimits = .standard) -> HardenedAITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIAccessStubURLProtocol.self]
        return HardenedAITransport(configuration: configuration, limits: limits)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = readBody()
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            headers[key.lowercased()] = value
        }
        let captured = Captured(url: url, method: request.httpMethod ?? "GET", headers: headers, body: body)
        let respond = Self.state.withLock { state -> @Sendable (URLRequest) -> Response in
            state.captured.append(captured)
            return state.respond
        }
        var withBody = request
        withBody.httpBody = body
        let response = respond(withBody)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

/// Counts `.cadenzaAIAccessDidFail` posts while alive.
final class CadenzaAccessFailureCounter: @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: .cadenzaAIAccessDidFail, object: nil, queue: nil) { [count] _ in
            count.withLock { $0 += 1 }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    var value: Int { count.withLock { $0 } }
}

let testCadenzaAPIBase = URL(string: "https://cadenzapp.com/api/v1")!

@Suite("AI provider access", .serialized)
struct AIProviderAccessTests {
    @Test func directURLsUseEachProvidersOrigin() throws {
        let cases: [(AIProvider, String, String)] = [
            (.openai, "/v1/chat/completions", "https://api.openai.com/v1/chat/completions"),
            (.claude, "/v1/messages", "https://api.anthropic.com/v1/messages"),
            (.gemini, "/v1beta/models/gemini-3.8-flash:streamGenerateContent",
             "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent"),
            (.minimax, "/v1/chat/completions", "https://api.minimax.io/v1/chat/completions"),
        ]
        for (provider, path, expected) in cases {
            let url = try AIProviderAccess.direct(provider, apiKey: "k").url(path: path)
            #expect(url.absoluteString == expected)
        }
    }

    @Test func cadenzaURLsGoThroughTheProxyUnderTheServerProviderName() throws {
        let cases: [(AIProvider, String)] = [(.openai, "openai"), (.claude, "anthropic"), (.gemini, "gemini"), (.minimax, "minimax")]
        for (provider, name) in cases {
            let access = AIProviderAccess(provider: provider, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session"))
            let url = try access.url(path: "/v1/models")
            #expect(url.absoluteString == "https://cadenzapp.com/api/v1/ai/proxy/\(name)/v1/models")
        }
        let gemini = AIProviderAccess(provider: .gemini, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
        let streaming = try gemini.url(
            path: "/v1beta/models/gemini-3.8-flash:streamGenerateContent",
            queryItems: [URLQueryItem(name: "alt", value: "sse")]
        )
        #expect(streaming.absoluteString
            == "https://cadenzapp.com/api/v1/ai/proxy/gemini/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse")
        #expect(gemini.realtimeCredentialsURL?.absoluteString == "https://cadenzapp.com/api/v1/ai/realtime/credentials")
        #expect(AIProviderAccess.direct(.gemini, apiKey: "k").realtimeCredentialsURL == nil)
    }

    @Test func deviceProvidersHaveNoURL() {
        #expect(throws: AITransportError.self) {
            try AIProviderAccess.direct(.apple, apiKey: "k").url(path: "/v1/models")
        }
    }

    @Test func authorizeAttachesOnlyTheRoutesCredential() throws {
        let direct: [(AIProvider, String, String)] = [
            (.openai, "Authorization", "Bearer sk-1"),
            (.minimax, "Authorization", "Bearer sk-1"),
            (.claude, "x-api-key", "sk-1"),
            (.gemini, "x-goog-api-key", "sk-1"),
        ]
        for (provider, header, value) in direct {
            var request = URLRequest(url: testCadenzaAPIBase)
            request.setValue("stale", forHTTPHeaderField: "x-api-key")
            AIProviderAccess.direct(provider, apiKey: "sk-1").authorize(&request)
            #expect(request.value(forHTTPHeaderField: header) == value)
            let others = ["Authorization", "x-api-key", "x-goog-api-key"].filter { $0 != header }
            #expect(others.allSatisfy { request.value(forHTTPHeaderField: $0) == nil })
        }

        var request = URLRequest(url: testCadenzaAPIBase)
        request.setValue("sk-device", forHTTPHeaderField: "x-goog-api-key")
        let cadenza = AIProviderAccess(provider: .gemini, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-1"))
        cadenza.authorize(&request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-1")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
        #expect(cadenza.secrets == ["session-1"])
        #expect(cadenza.directAPIKey == nil)
        #expect(AIProviderAccess.direct(.gemini, apiKey: "sk-1").directAPIKey == "sk-1")
    }

    @Test func cadenzaRouteIsNotHeldToTheProvidersPinnedHost() async throws {
        AIAccessStubURLProtocol.install { _ in .init() }
        let transport = AIAccessStubURLProtocol.transport()
        let access = AIProviderAccess(provider: .minimax, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
        var request = URLRequest(url: try access.url(path: "/v1/models"))
        access.authorize(&request)

        _ = try await transport.data(for: request, provider: .minimax, redacting: access.secrets, viaCadenza: true)
        await #expect(throws: AITransportError.self) {
            _ = try await transport.data(for: request, provider: .minimax, redacting: access.secrets)
        }
    }

    @Test func proxyOwnErrorsBecomeAccessErrorsAndRefreshKeyStatus() async throws {
        let counter = CadenzaAccessFailureCounter()
        let transport = AIAccessStubURLProtocol.transport()
        let access = AIProviderAccess(provider: .claude, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
        var request = URLRequest(url: try access.url(path: "/v1/messages"))
        request.httpMethod = "POST"
        access.authorize(&request)

        AIAccessStubURLProtocol.install { _ in
            .init(status: 409, headers: [CadenzaAIAccessError.headerName: "ai_key_invalid", "Content-Type": "application/json"],
                  body: Data(#"{"code":"ai_key_invalid"}"#.utf8))
        }
        await #expect(throws: CadenzaAIAccessError(code: "ai_key_invalid")) {
            _ = try await transport.data(for: request, provider: .claude, redacting: access.secrets, viaCadenza: true)
        }
        #expect(counter.value == 1)

        // Streams report the same error.
        let stream = transport.serverSentEvents(for: request, provider: .claude, redacting: access.secrets, viaCadenza: true)
        await #expect(throws: CadenzaAIAccessError(code: "ai_key_invalid")) {
            for try await _ in stream {}
        }
        #expect(counter.value == 2)

        // A rate limit is the proxy's too, but leaves the key status alone.
        AIAccessStubURLProtocol.install { _ in
            .init(status: 429, headers: [CadenzaAIAccessError.headerName: "rate_limited"], body: Data())
        }
        await #expect(throws: CadenzaAIAccessError(code: "rate_limited")) {
            _ = try await transport.data(for: request, provider: .claude, redacting: access.secrets, viaCadenza: true)
        }
        #expect(counter.value == 2)
    }

    @Test func providerRejectionThroughCadenzaRefreshesKeyStatus() async throws {
        let counter = CadenzaAccessFailureCounter()
        let transport = AIAccessStubURLProtocol.transport()
        AIAccessStubURLProtocol.install { _ in
            .init(status: 401, headers: ["X-Cadenza-Proxy": "1"], body: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8))
        }
        let viaCadenza = AIProviderAccess(provider: .claude, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
        var request = URLRequest(url: try viaCadenza.url(path: "/v1/messages"))
        viaCadenza.authorize(&request)
        await #expect(throws: AIServiceError.self) {
            _ = try await transport.data(for: request, provider: .claude, redacting: viaCadenza.secrets, viaCadenza: true)
        }
        #expect(counter.value == 1)

        // A direct call's rejection concerns the device's own key only.
        let direct = AIProviderAccess.direct(.claude, apiKey: "sk-device")
        var directRequest = URLRequest(url: try direct.url(path: "/v1/messages"))
        direct.authorize(&directRequest)
        await #expect(throws: AIServiceError.self) {
            _ = try await transport.data(for: directRequest, provider: .claude, redacting: direct.secrets)
        }
        #expect(counter.value == 1)
    }

    @Test func gatewayTimeoutBeforeTheProxyIsTheServersError() async throws {
        let counter = CadenzaAccessFailureCounter()
        let transport = AIAccessStubURLProtocol.transport()
        let access = AIProviderAccess(provider: .openai, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
        var request = URLRequest(url: try access.url(path: "/v1/audio/transcriptions"))
        request.httpMethod = "POST"
        access.authorize(&request)

        // The server's front end timed out; the proxy never answered, so the
        // response carries no proxy marker.
        AIAccessStubURLProtocol.install { _ in .init(status: 504, headers: [:], body: Data()) }
        await #expect(throws: CadenzaAIAccessError(code: "gateway_timeout")) {
            _ = try await transport.data(for: request, provider: .openai, redacting: access.secrets, viaCadenza: true)
        }
        let stream = transport.serverSentEvents(for: request, provider: .openai, redacting: access.secrets, viaCadenza: true)
        await #expect(throws: CadenzaAIAccessError(code: "gateway_timeout")) {
            for try await _ in stream {}
        }
        // A timeout says nothing about the account's keys.
        #expect(counter.value == 0)

        // The provider's own 504, passed through by the proxy, stays a provider error.
        AIAccessStubURLProtocol.install { _ in
            .init(status: 504, headers: ["X-Cadenza-Proxy": "1"], body: Data(#"{"error":{"message":"upstream timeout"}}"#.utf8))
        }
        do {
            _ = try await transport.data(for: request, provider: .openai, redacting: access.secrets, viaCadenza: true)
            Issue.record("expected a provider error")
        } catch AIServiceError.httpError(let status, _) {
            #expect(status == 504)
        }

        // So does a 504 on a direct call, marked or not.
        AIAccessStubURLProtocol.install { _ in .init(status: 504, headers: [:], body: Data()) }
        let direct = AIProviderAccess.direct(.openai, apiKey: "sk-device")
        var directRequest = URLRequest(url: try direct.url(path: "/v1/audio/transcriptions"))
        directRequest.httpMethod = "POST"
        direct.authorize(&directRequest)
        do {
            _ = try await transport.data(for: directRequest, provider: .openai, redacting: direct.secrets)
            Issue.record("expected a provider error")
        } catch AIServiceError.httpError(let status, _) {
            #expect(status == 504)
        }
    }

    @Test(arguments: ["ai_key_missing", "ai_key_invalid", "unauthenticated", "ai_usage_limit", "rate_limited", "ai_proxy_disabled", "provider_unreachable", "gateway_timeout"])
    func accessErrorsHaveMessages(code: String) {
        let message = CadenzaAIAccessError(code: code).localizedMessage()
        #expect(!message.isEmpty)
        #expect(!message.contains(code))
    }
}

@Suite("AI services through Cadenza", .serialized)
struct AIServicesThroughCadenzaTests {
    private func cadenza(_ provider: AIProvider) -> AIProviderAccess {
        AIProviderAccess(provider: provider, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
    }

    private func expectOnlySessionCredential(_ captured: AIAccessStubURLProtocol.Captured) {
        #expect(captured.headers["authorization"] == "Bearer session-token-4f9a2c")
        #expect(captured.headers["x-api-key"] == nil)
        #expect(captured.headers["x-goog-api-key"] == nil)
    }

    @Test func chatStreamsGoThroughTheProxy() async throws {
        let cases: [(AIProvider, String)] = [
            (.openai, "https://cadenzapp.com/api/v1/ai/proxy/openai/v1/chat/completions"),
            (.minimax, "https://cadenzapp.com/api/v1/ai/proxy/minimax/v1/chat/completions"),
            (.claude, "https://cadenzapp.com/api/v1/ai/proxy/anthropic/v1/messages"),
            (.gemini, "https://cadenzapp.com/api/v1/ai/proxy/gemini/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse"),
        ]
        for (provider, expectedURL) in cases {
            AIAccessStubURLProtocol.install { _ in
                .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data())
            }
            let access = cadenza(provider)
            let service: any AIServiceProtocol
            switch provider {
            case .openai, .minimax: service = OpenAIService(access: access, transport: AIAccessStubURLProtocol.transport())
            case .claude: service = ClaudeService(access: access, transport: AIAccessStubURLProtocol.transport())
            default: service = GeminiService(access: access, transport: AIAccessStubURLProtocol.transport())
            }
            let stream = service.streamChat(systemPrompt: "Be brief.", userMessage: "Hello team", model: provider == .gemini ? "gemini-3.8-flash" : nil)
            do { for try await _ in stream {} } catch {}
            let captured = try #require(AIAccessStubURLProtocol.captured.last)
            #expect(captured.url.absoluteString == expectedURL, "\(provider)")
            #expect(captured.method == "POST")
            expectOnlySessionCredential(captured)
            if provider == .claude {
                #expect(captured.headers["anthropic-version"] == "2023-06-01")
            }
        }
    }

    @Test func factoryKeepsTheRouteForEveryProvider() throws {
        let access = cadenza(.openai)
        for provider in [AIProvider.openai, .claude, .gemini, .minimax] {
            #expect(provider.makeChatService(access: access)?.provider == provider)
        }
    }

    @Test func modelListGoesThroughTheProxy() async throws {
        AIAccessStubURLProtocol.install { _ in
            .init(status: 200, headers: ["Content-Type": "application/json"],
                  body: Data(#"{"data":[{"id":"claude-sonnet-5-5"}]}"#.utf8))
        }
        let service = AIChatModelListService(transport: AIAccessStubURLProtocol.transport(limits: .modelList))
        let presets = try await service.fetchPresets(for: .claude, access: cadenza(.claude))
        #expect(presets.map(\.id).contains("claude-sonnet-5-5"))
        let captured = try #require(AIAccessStubURLProtocol.captured.last)
        #expect(captured.url.absoluteString == "https://cadenzapp.com/api/v1/ai/proxy/anthropic/v1/models")
        expectOnlySessionCredential(captured)
    }
}

@Suite("File transcription through Cadenza", .serialized)
struct FileTranscriptionThroughCadenzaTests {
    private func cadenza(_ provider: AIProvider) -> AIProviderAccess {
        AIProviderAccess(provider: provider, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
    }

    @Test func openAITranscriptionGoesThroughTheProxy() async throws {
        AIAccessStubURLProtocol.install { _ in .init(status: 200, body: Data(#"{"text":"Hello team"}"#.utf8)) }
        let client = OpenAITranscriptionAPIClient(access: cadenza(.openai), transport: AIAccessStubURLProtocol.transport(limits: .transcription))
        _ = try await client.transcribe(multipartBody: Data("--b\r\n".utf8), boundary: "b")
        let captured = try #require(AIAccessStubURLProtocol.captured.last)
        #expect(captured.url.absoluteString == "https://cadenzapp.com/api/v1/ai/proxy/openai/v1/audio/transcriptions")
        #expect(captured.headers["authorization"] == "Bearer session-token-4f9a2c")
        #expect(captured.headers["content-type"] == "multipart/form-data; boundary=b")
    }

    @Test func gatewayTimeoutFailsTheUploadWithoutRetrying() async throws {
        AIAccessStubURLProtocol.install { _ in .init(status: 504, headers: [:], body: Data()) }
        let client = OpenAITranscriptionAPIClient(access: cadenza(.openai), transport: AIAccessStubURLProtocol.transport(limits: .transcription))
        let sleeps = OSAllocatedUnfairLock(initialState: 0)
        let transcriber = WhisperTranscriber(
            model: "gpt-4o-transcribe-diarize",
            apiClient: client,
            retrySleep: { _ in sleeps.withLock { $0 += 1 } }
        )

        // Each retry would wait out the same front-end timeout again.
        await #expect(throws: CadenzaAIAccessError(code: "gateway_timeout")) {
            _ = try await transcriber.uploadWithRetry(body: WhisperMultipartBody(boundary: "b", data: Data("--b\r\n".utf8)))
        }
        #expect(AIAccessStubURLProtocol.captured.count == 1)
        #expect(sleeps.withLock { $0 } == 0)

        let timeout = CadenzaAIAccessError(code: "gateway_timeout")
        #expect(!WhisperTranscriber.isRetryableRequestError(timeout))
        #expect(!GeminiTranscriber.isRetryableRequestError(timeout))
        #expect(WhisperTranscriber.isRetryableRequestError(AIServiceError.httpError(504, "upstream timeout")))
    }

    @Test func geminiTranscriptionGoesThroughTheProxy() async throws {
        AIAccessStubURLProtocol.install { _ in .init(status: 200, body: Data("{}".utf8)) }
        let client = GeminiTranscriptionAPIClient(access: cadenza(.gemini), model: "gemini-3.8-flash",
                                                  transport: AIAccessStubURLProtocol.transport(limits: .transcription))
        _ = try await client.generateContent(body: Data("{}".utf8))
        _ = try await client.createInteraction(body: Data("{}".utf8))
        let urls = AIAccessStubURLProtocol.captured.suffix(2).map(\.url.absoluteString)
        #expect(urls == [
            "https://cadenzapp.com/api/v1/ai/proxy/gemini/v1beta/models/gemini-3.8-flash:generateContent",
            "https://cadenzapp.com/api/v1/ai/proxy/gemini/v1beta/interactions",
        ])
        #expect(AIAccessStubURLProtocol.captured.suffix(2).allSatisfy {
            $0.headers["authorization"] == "Bearer session-token-4f9a2c" && $0.headers["x-goog-api-key"] == nil
        })
    }
}

@Suite("Realtime credentials through Cadenza", .serialized)
struct RealtimeCredentialsThroughCadenzaTests {
    private func cadenza(_ provider: AIProvider) -> AIProviderAccess {
        AIProviderAccess(provider: provider, route: .cadenza(apiBase: testCadenzaAPIBase, sessionToken: "session-token-4f9a2c"))
    }

    @Test func mintAsksTheServerForOneConnectionsCredential() async throws {
        AIAccessStubURLProtocol.install { _ in
            .init(status: 200, body: Data(#"{"provider":"openai","credential":"ek_minted_123","expires_at":"2026-09-30T20:17:05Z"}"#.utf8))
        }
        let credential = try await CadenzaRealtimeCredentials.mint(
            access: cadenza(.openai), model: "gpt-live-transcribe",
            transport: AIAccessStubURLProtocol.transport(limits: .ephemeralToken)
        )
        #expect(credential == "ek_minted_123")
        let captured = try #require(AIAccessStubURLProtocol.captured.last)
        #expect(captured.url.absoluteString == "https://cadenzapp.com/api/v1/ai/realtime/credentials")
        #expect(captured.method == "POST")
        #expect(captured.headers["authorization"] == "Bearer session-token-4f9a2c")
        let body = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: String])
        #expect(body == ["provider": "openai", "model": "gpt-live-transcribe"])
    }

    @Test func mintReportsTheServersOwnErrors() async throws {
        AIAccessStubURLProtocol.install { _ in
            .init(status: 409, headers: [CadenzaAIAccessError.headerName: "ai_key_missing"], body: Data(#"{"code":"ai_key_missing"}"#.utf8))
        }
        await #expect(throws: CadenzaAIAccessError(code: "ai_key_missing")) {
            _ = try await CadenzaRealtimeCredentials.mint(
                access: self.cadenza(.gemini), model: "gemini-3.5-transcribe-live",
                transport: AIAccessStubURLProtocol.transport(limits: .ephemeralToken)
            )
        }
    }

    @Test func openAITranscriberMintsInsteadOfUsingAKey() async throws {
        let mints = MintCounter()
        let cloud = RealtimeTranscriber(
            access: cadenza(.openai), model: "gpt-live-transcribe",
            mintCredential: { access, model in
                await mints.record(access: access, model: model)
                return "ek_connection_\(await mints.count)"
            }
        )
        #expect(try await cloud._testBearer() == "ek_connection_1")
        #expect(await mints.count == 1)
        #expect(await mints.lastModel == "gpt-live-transcribe")
        #expect(await mints.lastWasCadenza)

        let direct = RealtimeTranscriber(access: .direct(.openai, apiKey: "sk-device"), model: "gpt-live-transcribe")
        #expect(try await direct._testBearer() == "sk-device")
    }

    @Test func geminiCloudTokensAreFreshAndValidated() async throws {
        let mints = MintCounter()
        let operation = GeminiRealtimeTranscriber.cloudTokenOperation(
            access: cadenza(.gemini), model: "gemini-3.5-transcribe-live",
            mint: { access, model in
                await mints.record(access: access, model: model)
                return "auth_tokens/token\(await mints.count)"
            }
        )
        #expect(try await operation() == "auth_tokens/token1")
        #expect(try await operation() == "auth_tokens/token2")
        #expect(await mints.count == 2)

        let malformed = GeminiRealtimeTranscriber.cloudTokenOperation(
            access: cadenza(.gemini), model: "gemini-3.5-transcribe-live",
            mint: { _, _ in "sk-not-a-token" }
        )
        await #expect(throws: AIServiceError.self) { _ = try await malformed() }
    }
}

private actor MintCounter {
    private(set) var count = 0
    private(set) var lastModel: String?
    private(set) var lastWasCadenza = false

    func record(access: AIProviderAccess, model: String) {
        count += 1
        lastModel = model
        lastWasCadenza = access.viaCadenza
    }
}
