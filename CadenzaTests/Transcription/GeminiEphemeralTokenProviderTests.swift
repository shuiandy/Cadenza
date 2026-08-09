import Foundation
import Synchronization
import Testing

@testable import Cadenza

@Suite("Gemini ephemeral token provider", .serialized)
struct GeminiEphemeralTokenProviderTests {
    @Test func tokenClientUsesHeaderOnlyBoundedRequestAndNameOnlyResponse() async throws {
        GeminiTokenTestURLProtocol.reset()
        let secret = "gemini-long-lived-secret"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = GeminiEphemeralTokenClient(
            apiKey: secret,
            transport: makeTransport()
        )

        let token = try await client.mint(at: now)
        let request = try #require(GeminiTokenTestURLProtocol.capturedRequest)
        let body = try #require(request.body)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(token.name == "auth_tokens/token-one")
        #expect(
            token.newSessionExpireTime
                == Date(timeIntervalSince1970: 1_800_000_120)
        )
        #expect(request.urlString == "https://generativelanguage.googleapis.com/v1alpha/auth_tokens")
        #expect(request.urlString.contains(secret) == false)
        #expect(request.apiKey == secret)
        #expect(request.method == "POST")
        #expect(request.contentType == "application/json")
        #expect(json["uses"] as? Int == 0)
        #expect(json["expireTime"] as? String != nil)
        #expect(json["newSessionExpireTime"] as? String != nil)
    }

    @Test func tokenClientRejectsOversizedResponse() async throws {
        GeminiTokenTestURLProtocol.reset(mode: .oversized)
        let client = GeminiEphemeralTokenClient(
            apiKey: "gemini-long-lived-secret",
            transport: makeTransport(maxBufferedResponseBytes: 32)
        )

        await #expect(throws: AITransportError.self) {
            _ = try await client.mint(at: Date())
        }
    }

    @Test func tokenClientDoesNotTrustProviderEchoedExpiry() async throws {
        GeminiTokenTestURLProtocol.reset(mode: .echoedFarFutureExpiry)
        let client = GeminiEphemeralTokenClient(
            apiKey: "gemini-long-lived-secret",
            transport: makeTransport()
        )

        let token = try await client.mint(
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(token.name == "auth_tokens/token-one")
        #expect(
            token.newSessionExpireTime
                == Date(timeIntervalSince1970: 1_800_000_120)
        )
    }

    @Test func tokenClientNeverReturnsProviderEchoedLongLivedKey() async throws {
        GeminiTokenTestURLProtocol.reset(mode: .errorEcho)
        let secret = "gemini-token-error-secret"
        let client = GeminiEphemeralTokenClient(
            apiKey: secret,
            transport: makeTransport()
        )

        do {
            _ = try await client.mint(at: Date())
            Issue.record("expected token provider error")
        } catch {
            #expect(error.localizedDescription.contains(secret) == false)
            #expect(error.localizedDescription.utf8.count < 512)
        }
    }

    @Test(arguments: [
        "",
        "token-without-prefix",
        "auth_tokens/",
        "auth_tokens/token with space",
        "auth_tokens/token\r\nInjected: yes",
        "auth_tokens/" + String(repeating: "x", count: 1_024),
    ])
    func tokenClientRejectsUnsafeTokenNames(_ name: String) async throws {
        GeminiTokenTestURLProtocol.reset(mode: .tokenName(name))
        let client = GeminiEphemeralTokenClient(
            apiKey: "gemini-long-lived-secret",
            transport: makeTransport(maxBufferedResponseBytes: 4_096)
        )

        await #expect(throws: GeminiEphemeralTokenError.self) {
            _ = try await client.mint(at: Date())
        }
    }

    @Test func concurrentCallersShareOneMintRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = SuspendedTokenMintProbe()
        let provider = GeminiEphemeralTokenProvider(
            now: { now },
            refreshMargin: 15,
            mint: { date in try await probe.mint(at: date) }
        )

        let tasks = (0..<8).map { _ in
            Task { try await provider.token() }
        }
        #expect(await waitUntil { await probe.invocationCount == 1 })
        await probe.succeed(
            GeminiEphemeralToken(
                name: "auth_tokens/shared",
                newSessionExpireTime: now.addingTimeInterval(120)
            )
        )

        var tokens: [String] = []
        for task in tasks {
            tokens.append(try await task.value)
        }
        #expect(Set(tokens) == ["auth_tokens/shared"])
        #expect(await probe.invocationCount == 1)
    }

    @Test func cachedTokenRefreshesBeforeNewSessionExpiry() async throws {
        let clock = ManualGeminiTokenClock(
            Date(timeIntervalSince1970: 1_800_000_000)
        )
        let probe = SequencedTokenMintProbe(tokens: [
            GeminiEphemeralToken(
                name: "auth_tokens/first",
                newSessionExpireTime: clock.now.addingTimeInterval(60)
            ),
            GeminiEphemeralToken(
                name: "auth_tokens/second",
                newSessionExpireTime: clock.now.addingTimeInterval(180)
            ),
        ])
        let provider = GeminiEphemeralTokenProvider(
            now: { clock.now },
            refreshMargin: 15,
            mint: { date in try await probe.mint(at: date) }
        )

        #expect(try await provider.token() == "auth_tokens/first")
        #expect(try await provider.token() == "auth_tokens/first")
        #expect(await probe.invocationCount == 1)

        clock.advance(by: 46)
        #expect(try await provider.token() == "auth_tokens/second")
        #expect(await probe.invocationCount == 2)
    }

    @Test func soleCancelledWaiterCancelsMintAndAllowsNewAttempt() async throws {
        let probe = CancellableTokenMintProbe()
        let provider = GeminiEphemeralTokenProvider(
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            refreshMargin: 15,
            mint: { date in try await probe.mint(at: date) }
        )

        let first = Task { try await provider.token() }
        #expect(await waitUntil { await probe.invocationCount == 1 })
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        #expect(await waitUntil { await probe.cancellationCount == 1 })

        let second = Task { try await provider.token() }
        #expect(await waitUntil { await probe.invocationCount == 2 })
        second.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await second.value
        }
    }

    @Test func oneCancelledWaiterReturnsPromptlyWhileSharedMintContinues() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = SuspendedTokenMintProbe()
        let provider = GeminiEphemeralTokenProvider(
            now: { now },
            refreshMargin: 15,
            mint: { date in try await probe.mint(at: date) }
        )

        let cancelledWaiter = Task { try await provider.token() }
        let survivingWaiter = Task { try await provider.token() }
        #expect(await waitUntil { await probe.invocationCount == 1 })

        cancelledWaiter.cancel()
        do {
            _ = try await HardAsyncDeadline.run(for: .milliseconds(100)) {
                try await cancelledWaiter.value
            }
            Issue.record("expected cancelled waiter to throw")
        } catch is CancellationError {
            // Expected: one cancelled caller must not wait for the shared mint.
        } catch {
            Issue.record("cancelled waiter did not return promptly: \(error)")
        }

        await probe.succeed(
            GeminiEphemeralToken(
                name: "auth_tokens/shared-after-cancel",
                newSessionExpireTime: now.addingTimeInterval(120)
            )
        )
        #expect(try await survivingWaiter.value == "auth_tokens/shared-after-cancel")
        #expect(await probe.invocationCount == 1)
    }

    @Test func failedMintIsGenericAndNextCallStartsFreshRequest() async throws {
        let secret = "must-not-escape"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = FailThenSucceedTokenMintProbe(secret: secret, now: now)
        let provider = GeminiEphemeralTokenProvider(
            now: { now },
            refreshMargin: 15,
            mint: { date in try await probe.mint(at: date) }
        )

        do {
            _ = try await provider.token()
            Issue.record("expected first mint to fail")
        } catch {
            #expect(error.localizedDescription.contains(secret) == false)
        }

        #expect(try await provider.token() == "auth_tokens/recovered")
        #expect(await probe.invocationCount == 2)
    }

    @Test func providerRevalidatesMintedCredentialBeforeCaching() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = GeminiEphemeralTokenProvider(
            now: { now },
            refreshMargin: 15,
            mint: { _ in
                GeminiEphemeralToken(
                    name: "long-lived-secret",
                    newSessionExpireTime: now.addingTimeInterval(120)
                )
            }
        )

        await #expect(throws: GeminiEphemeralTokenError.self) {
            _ = try await provider.token()
        }
    }

    private func makeTransport(
        maxBufferedResponseBytes: Int = 1_024
    ) -> HardenedAITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiTokenTestURLProtocol.self]
        return HardenedAITransport(
            configuration: configuration,
            limits: AITransportLimits(
                maxBufferedResponseBytes: maxBufferedResponseBytes,
                maxErrorResponseBytes: 128,
                maxSSETotalBytes: 1,
                maxSSELineBytes: 1,
                maxSSEFrameCount: 1,
                maxStreamDuration: .seconds(10)
            ),
            maximumRequestTimeout: 10
        )
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private final class ManualGeminiTokenClock: Sendable {
    private let value: Mutex<Date>

    init(_ date: Date) {
        self.value = Mutex(date)
    }

    var now: Date {
        value.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private actor SuspendedTokenMintProbe {
    private(set) var invocationCount = 0
    private var continuation: CheckedContinuation<GeminiEphemeralToken, Error>?

    func mint(at date: Date) async throws -> GeminiEphemeralToken {
        _ = date
        invocationCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(_ token: GeminiEphemeralToken) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: token)
    }
}

private actor SequencedTokenMintProbe {
    private(set) var invocationCount = 0
    private var tokens: [GeminiEphemeralToken]

    init(tokens: [GeminiEphemeralToken]) {
        self.tokens = tokens
    }

    func mint(at date: Date) throws -> GeminiEphemeralToken {
        _ = date
        invocationCount += 1
        guard !tokens.isEmpty else {
            throw GeminiEphemeralTokenError.requestFailed
        }
        return tokens.removeFirst()
    }
}

private actor CancellableTokenMintProbe {
    private(set) var invocationCount = 0
    private(set) var cancellationCount = 0

    func mint(at date: Date) async throws -> GeminiEphemeralToken {
        _ = date
        invocationCount += 1
        do {
            try await Task.sleep(for: .seconds(3_600))
            throw GeminiEphemeralTokenError.requestFailed
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private actor FailThenSucceedTokenMintProbe {
    private(set) var invocationCount = 0
    private let secret: String
    private let now: Date

    init(secret: String, now: Date) {
        self.secret = secret
        self.now = now
    }

    func mint(at date: Date) throws -> GeminiEphemeralToken {
        _ = date
        invocationCount += 1
        if invocationCount == 1 {
            throw NSError(
                domain: "GeminiTokenTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "network error containing \(secret)"]
            )
        }
        return GeminiEphemeralToken(
            name: "auth_tokens/recovered",
            newSessionExpireTime: now.addingTimeInterval(120)
        )
    }
}

private final class GeminiTokenTestURLProtocol: URLProtocol {
    enum Mode: Sendable {
        case success
        case oversized
        case errorEcho
        case echoedFarFutureExpiry
        case tokenName(String)
    }

    struct CapturedRequest: Sendable {
        let urlString: String
        let apiKey: String?
        let method: String?
        let contentType: String?
        let body: Data?
    }

    private struct State: Sendable {
        var mode: Mode = .success
        var capturedRequest: CapturedRequest?
    }

    private static let state = Mutex(State())

    static var capturedRequest: CapturedRequest? {
        state.withLock { $0.capturedRequest }
    }

    static func reset(mode: Mode = .success) {
        state.withLock { $0 = State(mode: mode) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let mode = Self.state.withLock { state -> Mode in
            state.capturedRequest = CapturedRequest(
                urlString: url.absoluteString,
                apiKey: request.value(forHTTPHeaderField: "x-goog-api-key"),
                method: request.httpMethod,
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: requestBodyData()
            )
            return state.mode
        }

        switch mode {
        case .success:
            sendToken(name: "auth_tokens/token-one", url: url)
        case .oversized:
            send(statusCode: 200, body: Data(repeating: 0x61, count: 64), url: url)
        case .errorEcho:
            let secret = request.value(forHTTPHeaderField: "x-goog-api-key") ?? "missing"
            send(
                statusCode: 401,
                body: Data(String(repeating: "echo \(secret) ", count: 32).utf8),
                url: url
            )
        case .echoedFarFutureExpiry:
            sendToken(
                name: "auth_tokens/token-one",
                expiry: "2099-01-15T08:02:00Z",
                url: url
            )
        case .tokenName(let name):
            sendToken(name: name, url: url)
        }
    }

    override func stopLoading() {}

    private func sendToken(
        name: String,
        expiry: String? = nil,
        url: URL
    ) {
        var object: [String: Any] = ["name": name]
        if let expiry {
            object["newSessionExpireTime"] = expiry
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        send(statusCode: 200, body: data, url: url)
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

    private func requestBodyData() -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
