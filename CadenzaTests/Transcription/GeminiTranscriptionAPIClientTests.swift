import Foundation
import Synchronization
import Testing

@testable import Cadenza

@Suite("Gemini transcription API transport", .serialized)
struct GeminiTranscriptionAPIClientTests {
    @Test func requestUsesHeaderOnlyAuthenticationAndStrictEndpoint() async throws {
        GeminiTranscriptionTestURLProtocol.reset()
        let secret = "gemini-batch-secret"
        let client = GeminiTranscriptionAPIClient(
            apiKey: secret,
            model: "gemini-3.5-flash",
            transport: makeTransport()
        )

        let data = try await client.generateContent(body: Data("{}".utf8))
        let request = try #require(GeminiTranscriptionTestURLProtocol.capturedRequest)

        #expect(String(decoding: data, as: UTF8.self) == "{\"ok\":true}")
        #expect(
            request.urlString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent"
        )
        #expect(request.urlString.contains(secret) == false)
        #expect(request.apiKey == secret)
        #expect(request.contentType == "application/json")
        #expect(request.method == "POST")
        #expect(request.body == Data("{}".utf8))
        #expect(request.timeoutInterval == 300)
    }

    @Test(arguments: [302, 307, 308])
    func redirectIsRejectedBeforeTargetReceivesRequest(statusCode: Int) async throws {
        GeminiTranscriptionTestURLProtocol.reset(mode: .redirect(statusCode))
        let client = GeminiTranscriptionAPIClient(
            apiKey: "gemini-batch-secret",
            model: "gemini-3.5-flash",
            transport: makeTransport()
        )

        await #expect(throws: Error.self) {
            _ = try await client.generateContent(body: Data("{}".utf8))
        }

        #expect(
            GeminiTranscriptionTestURLProtocol.requestCount(forHost: "redirect-target.example")
                == 0
        )
    }

    @Test func oversizedSuccessResponseIsRejected() async throws {
        GeminiTranscriptionTestURLProtocol.reset(mode: .oversized)
        let client = GeminiTranscriptionAPIClient(
            apiKey: "gemini-batch-secret",
            model: "gemini-3.5-flash",
            transport: makeTransport(maxBufferedResponseBytes: 32)
        )

        await #expect(throws: AITransportError.self) {
            _ = try await client.generateContent(body: Data("{}".utf8))
        }
    }

    @Test func providerErrorIsBoundedAndCannotEchoAPIKey() async throws {
        GeminiTranscriptionTestURLProtocol.reset(mode: .errorEcho)
        let secret = "gemini-batch-error-secret"
        let client = GeminiTranscriptionAPIClient(
            apiKey: secret,
            model: "gemini-3.5-flash",
            transport: makeTransport()
        )

        do {
            _ = try await client.generateContent(body: Data("{}".utf8))
            Issue.record("expected provider error")
        } catch {
            #expect(error.localizedDescription.contains(secret) == false)
            #expect(error.localizedDescription.utf8.count < 512)
        }
    }

    @Test func finalResponseOriginMustMatchGoogleOrigin() async throws {
        GeminiTranscriptionTestURLProtocol.reset(mode: .originMismatch)
        let client = GeminiTranscriptionAPIClient(
            apiKey: "gemini-batch-secret",
            model: "gemini-3.5-flash",
            transport: makeTransport()
        )

        await #expect(throws: AITransportError.self) {
            _ = try await client.generateContent(body: Data("{}".utf8))
        }
    }

    @Test(arguments: [
        "",
        "models/gemini-3.5-flash",
        "../gemini-3.5-flash",
        "gemini-3.5-flash?key=secret",
        "gemini-3.5-flash%2Fother",
        "gemini-" + String(repeating: "x", count: 257),
    ])
    func invalidModelCannotChangeRequestPath(_ model: String) async throws {
        GeminiTranscriptionTestURLProtocol.reset()
        let client = GeminiTranscriptionAPIClient(
            apiKey: "gemini-batch-secret",
            model: model,
            transport: makeTransport()
        )

        await #expect(throws: AITransportError.self) {
            _ = try await client.generateContent(body: Data("{}".utf8))
        }
        #expect(GeminiTranscriptionTestURLProtocol.totalRequestCount == 0)
    }

    @Test func retryClassificationUsesTypedTransportAndHTTPFailures() {
        #expect(GeminiTranscriber.isRetryableRequestError(AITransportError.requestFailed))
        #expect(
            GeminiTranscriber.isRetryableRequestError(
                AIServiceError.httpError(429, "rate limited")
            )
        )
        #expect(
            GeminiTranscriber.isRetryableRequestError(
                AIServiceError.httpError(500, "provider unavailable")
            )
        )
        #expect(
            GeminiTranscriber.isRetryableRequestError(
                AIServiceError.httpError(599, "provider unavailable")
            )
        )
        #expect(
            GeminiTranscriber.isRetryableRequestError(
                AIServiceError.httpError(400, "bad request")
            ) == false
        )
        #expect(
            GeminiTranscriber.isRetryableRequestError(AITransportError.unsafeEndpoint)
                == false
        )
    }

    private func makeTransport(
        maxBufferedResponseBytes: Int = 1_024
    ) -> HardenedAITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiTranscriptionTestURLProtocol.self]
        return HardenedAITransport(
            configuration: configuration,
            limits: AITransportLimits(
                maxBufferedResponseBytes: maxBufferedResponseBytes,
                maxErrorResponseBytes: 128,
                maxSSETotalBytes: 1,
                maxSSELineBytes: 1,
                maxSSEFrameCount: 1,
                maxStreamDuration: .seconds(600)
            )
        )
    }
}

private final class GeminiTranscriptionTestURLProtocol: URLProtocol {
    enum Mode: Sendable {
        case success
        case redirect(Int)
        case oversized
        case errorEcho
        case originMismatch
    }

    struct CapturedRequest: Sendable {
        let urlString: String
        let apiKey: String?
        let contentType: String?
        let method: String?
        let body: Data?
        let timeoutInterval: TimeInterval
    }

    private struct State: Sendable {
        var mode: Mode = .success
        var capturedRequest: CapturedRequest?
        var requestCountByHost: [String: Int] = [:]
    }

    private static let state = Mutex(State())

    static var capturedRequest: CapturedRequest? {
        state.withLock { $0.capturedRequest }
    }

    static var totalRequestCount: Int {
        state.withLock { $0.requestCountByHost.values.reduce(0, +) }
    }

    static func reset(mode: Mode = .success) {
        state.withLock { $0 = State(mode: mode) }
    }

    static func requestCount(forHost host: String) -> Int {
        state.withLock { $0.requestCountByHost[host, default: 0] }
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

        let mode = Self.state.withLock { state -> Mode in
            state.requestCountByHost[host, default: 0] += 1
            state.capturedRequest = CapturedRequest(
                urlString: url.absoluteString,
                apiKey: request.value(forHTTPHeaderField: "x-goog-api-key"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                method: request.httpMethod,
                body: requestBodyData(),
                timeoutInterval: request.timeoutInterval
            )
            return state.mode
        }

        switch mode {
        case .success:
            send(statusCode: 200, body: Data("{\"ok\":true}".utf8), url: url)
        case .redirect(let statusCode):
            let target = URL(string: "https://redirect-target.example/collect")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: target),
                redirectResponse: response
            )
            client?.urlProtocolDidFinishLoading(self)
        case .oversized:
            send(statusCode: 200, body: Data(repeating: 0x61, count: 64), url: url)
        case .errorEcho:
            let secret = request.value(forHTTPHeaderField: "x-goog-api-key") ?? "missing"
            send(
                statusCode: 401,
                body: Data(String(repeating: "echo \(secret) ", count: 32).utf8),
                url: url
            )
        case .originMismatch:
            send(
                statusCode: 200,
                body: Data("{}".utf8),
                url: URL(string: "https://different-origin.example/response")!
            )
        }
    }

    override func stopLoading() {}

    private func requestBodyData() -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func send(statusCode: Int, body: Data, url: URL) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
