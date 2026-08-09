import Foundation
import Synchronization
import Testing

@testable import Cadenza

@Suite("OpenAI transcription API transport", .serialized)
struct OpenAITranscriptionAPIClientTests {
    @Test func requestUsesHeaderAuthenticationAndInjectedBoundedTransport() async throws {
        OpenAITranscriptionTestURLProtocol.reset()
        let secret = "openai-transcription-secret"
        let body = Data("multipart payload".utf8)
        let client = OpenAITranscriptionAPIClient(
            apiKey: secret,
            transport: makeTransport()
        )

        let data = try await client.transcribe(
            multipartBody: body,
            boundary: "test-boundary"
        )
        let request = try #require(OpenAITranscriptionTestURLProtocol.capturedRequest)

        #expect(String(decoding: data, as: UTF8.self).contains("transport protected"))
        #expect(request.urlString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.urlString.contains(secret) == false)
        #expect(request.authorization == "Bearer \(secret)")
        #expect(request.contentType == "multipart/form-data; boundary=test-boundary")
        #expect(request.method == "POST")
        #expect(request.body == body)
        #expect(request.timeoutInterval == 300)
    }

    @Test(arguments: [302, 307, 308])
    func redirectIsRejectedBeforeTargetReceivesAuthorization(statusCode: Int) async throws {
        OpenAITranscriptionTestURLProtocol.reset(mode: .redirect(statusCode))
        let client = OpenAITranscriptionAPIClient(
            apiKey: "openai-redirect-secret",
            transport: makeTransport()
        )

        await #expect(throws: Error.self) {
            _ = try await client.transcribe(
                multipartBody: Data("body".utf8),
                boundary: "boundary"
            )
        }

        #expect(
            OpenAITranscriptionTestURLProtocol.requestCount(
                forHost: "redirect-target.example"
            ) == 0
        )
        #expect(OpenAITranscriptionTestURLProtocol.authorizationObservedByTarget == nil)
    }

    @Test func oversizedSuccessResponseIsRejected() async throws {
        OpenAITranscriptionTestURLProtocol.reset(mode: .oversized)
        let client = OpenAITranscriptionAPIClient(
            apiKey: "openai-oversize-secret",
            transport: makeTransport(maxBufferedResponseBytes: 32)
        )

        await #expect(throws: AITransportError.self) {
            _ = try await client.transcribe(
                multipartBody: Data("body".utf8),
                boundary: "boundary"
            )
        }
    }

    @Test func providerErrorIsBoundedAndCannotEchoAPIKey() async throws {
        OpenAITranscriptionTestURLProtocol.reset(mode: .errorEcho)
        let secret = "openai-error-secret"
        let client = OpenAITranscriptionAPIClient(
            apiKey: secret,
            transport: makeTransport()
        )

        do {
            _ = try await client.transcribe(
                multipartBody: Data("body".utf8),
                boundary: "boundary"
            )
            Issue.record("expected provider error")
        } catch {
            #expect(error.localizedDescription.contains(secret) == false)
            #expect(error.localizedDescription.utf8.count < 512)
        }
    }

    @Test func finalResponseOriginMustMatchOpenAIOrigin() async throws {
        OpenAITranscriptionTestURLProtocol.reset(mode: .originMismatch)
        let client = OpenAITranscriptionAPIClient(
            apiKey: "openai-origin-secret",
            transport: makeTransport()
        )

        await #expect(throws: AITransportError.self) {
            _ = try await client.transcribe(
                multipartBody: Data("body".utf8),
                boundary: "boundary"
            )
        }
    }

    @Test func callerCancellationIsPreservedByTransport() async throws {
        OpenAITranscriptionTestURLProtocol.reset(mode: .hanging)
        let client = OpenAITranscriptionAPIClient(
            apiKey: "openai-cancel-secret",
            transport: makeTransport()
        )
        let task = Task {
            try await client.transcribe(
                multipartBody: Data("body".utf8),
                boundary: "boundary"
            )
        }

        #expect(await waitUntil {
            OpenAITranscriptionTestURLProtocol.totalRequestCount == 1
        })
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await waitUntil {
            OpenAITranscriptionTestURLProtocol.stopLoadingCount == 1
        })
    }

    @Test func retryableTypedFailuresPreserveThreeAttemptsAndBackoff() async throws {
        let client = ScriptedOpenAITranscriptionClient(outcomes: [
            .http(429),
            .http(503),
            .success(Self.validTranscriptResponse),
        ])
        let delays = OpenAIRetryDelayRecorder()
        let transcriber = makeTranscriber(client: client, delays: delays)

        let result = try await transcriber.uploadWithRetry(
            body: WhisperMultipartBody(
                boundary: "boundary",
                data: Data("body".utf8)
            )
        )

        #expect(result.text == "hello")
        #expect(await client.requestCount == 3)
        #expect(await delays.values == [.seconds(2), .seconds(4)])
    }

    @Test func transientTransportFailureIsRetried() async throws {
        let client = ScriptedOpenAITranscriptionClient(outcomes: [
            .requestFailed,
            .success(Self.validTranscriptResponse),
        ])
        let delays = OpenAIRetryDelayRecorder()
        let transcriber = makeTranscriber(client: client, delays: delays)

        _ = try await transcriber.uploadWithRetry(
            body: WhisperMultipartBody(boundary: "boundary", data: Data())
        )

        #expect(await client.requestCount == 2)
        #expect(await delays.values == [.seconds(2)])
    }

    @Test func nonretryableHTTPFailureStopsAfterOneAttempt() async throws {
        let client = ScriptedOpenAITranscriptionClient(outcomes: [.http(400)])
        let delays = OpenAIRetryDelayRecorder()
        let transcriber = makeTranscriber(client: client, delays: delays)

        await #expect(throws: AIServiceError.self) {
            _ = try await transcriber.uploadWithRetry(
                body: WhisperMultipartBody(boundary: "boundary", data: Data())
            )
        }

        #expect(await client.requestCount == 1)
        #expect(await delays.values.isEmpty)
    }

    @Test func repeatedServerFailureStopsAfterThreeAttempts() async throws {
        let client = ScriptedOpenAITranscriptionClient(outcomes: [
            .http(503),
            .http(503),
            .http(503),
        ])
        let delays = OpenAIRetryDelayRecorder()
        let transcriber = makeTranscriber(client: client, delays: delays)

        await #expect(throws: AIServiceError.self) {
            _ = try await transcriber.uploadWithRetry(
                body: WhisperMultipartBody(boundary: "boundary", data: Data())
            )
        }

        #expect(await client.requestCount == 3)
        #expect(await delays.values == [.seconds(2), .seconds(4)])
    }

    @Test func cancellationNeverRetries() async throws {
        let client = ScriptedOpenAITranscriptionClient(outcomes: [
            .cancelled,
            .success(Self.validTranscriptResponse),
        ])
        let delays = OpenAIRetryDelayRecorder()
        let transcriber = makeTranscriber(client: client, delays: delays)

        await #expect(throws: CancellationError.self) {
            _ = try await transcriber.uploadWithRetry(
                body: WhisperMultipartBody(boundary: "boundary", data: Data())
            )
        }

        #expect(await client.requestCount == 1)
        #expect(await delays.values.isEmpty)
    }

    @Test func cancellationDuringBackoffNeverStartsAnotherRequest() async throws {
        let client = ScriptedOpenAITranscriptionClient(outcomes: [
            .requestFailed,
            .success(Self.validTranscriptResponse),
        ])
        let transcriber = WhisperTranscriber(
            model: "gpt-4o-transcribe",
            apiClient: client,
            retrySleep: { _ in throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await transcriber.uploadWithRetry(
                body: WhisperMultipartBody(boundary: "boundary", data: Data())
            )
        }

        #expect(await client.requestCount == 1)
    }

    @Test func retryBackoffDoesNotHoldAnUploadPermit() async throws {
        let client = ScriptedOpenAITranscriptionClient(outcomes: [
            .requestFailed,
            .success(Self.validTranscriptResponse),
            .success(Self.validTranscriptResponse),
        ])
        let retryGate = OpenAIAsyncGate()
        let transcriber = WhisperTranscriber(
            model: "gpt-4o-transcribe",
            apiClient: client,
            retrySleep: { _ in await retryGate.wait() }
        )
        let permits = AsyncPermitPool(limit: 1)
        let body = WhisperMultipartBody(boundary: "boundary", data: Data())

        let retryingUpload = Task {
            try await transcriber.uploadWithRetry(body: body, apiPermits: permits)
        }
        #expect(await waitUntil { await retryGate.waitingCount == 1 })

        let independentUpload = Task {
            try await transcriber.uploadWithRetry(body: body, apiPermits: permits)
        }
        let independentRequestStarted = await waitUntil(timeout: .milliseconds(250)) {
            await client.requestCount >= 2
        }

        #expect(independentRequestStarted)
        await retryGate.open()
        #expect(try await independentUpload.value.text == "hello")
        #expect(try await retryingUpload.value.text == "hello")
        #expect(await client.requestCount == 3)
    }

    @Test func uploadAttemptsNeverExceedConfiguredPermitLimit() async throws {
        let gate = OpenAIAsyncGate()
        let probe = OpenAIUploadConcurrencyProbe()
        let client = ConcurrentOpenAITranscriptionClient(
            response: Self.validTranscriptResponse,
            gate: gate,
            probe: probe
        )
        let transcriber = WhisperTranscriber(
            model: "gpt-4o-transcribe",
            apiClient: client,
            retrySleep: { _ in }
        )
        let permits = AsyncPermitPool(limit: 6)
        let body = WhisperMultipartBody(boundary: "boundary", data: Data())
        let uploads = (0..<8).map { _ in
            Task {
                try await transcriber.uploadWithRetry(body: body, apiPermits: permits)
            }
        }

        #expect(await waitUntil { await probe.activeCount == 6 })
        #expect(await probe.maximumActiveCount == 6)
        #expect(await probe.requestCount == 6)

        await gate.open()
        for upload in uploads {
            #expect(try await upload.value.text == "hello")
        }

        #expect(await probe.requestCount == 8)
        #expect(await probe.maximumActiveCount == 6)
        #expect(await probe.activeCount == 0)
    }

    @Test func multipartBodyIsBuiltOnlyAfterAnUploadPermitIsAcquired() async throws {
        let permits = AsyncPermitPool(limit: 1)
        let holderGate = OpenAIAsyncGate()
        let holderStarted = Mutex(false)
        let holder = Task {
            try await permits.withPermit {
                holderStarted.withLock { $0 = true }
                await holderGate.wait()
            }
        }
        #expect(await waitUntil { holderStarted.withLock { $0 } })

        let bodyBuildCount = Mutex(0)
        let client = ScriptedOpenAITranscriptionClient(outcomes: [
            .success(Self.validTranscriptResponse),
        ])
        let transcriber = WhisperTranscriber(
            model: "gpt-4o-transcribe",
            apiClient: client,
            retrySleep: { _ in }
        )
        let upload = Task {
            try await transcriber.uploadWithRetry(apiPermits: permits) {
                bodyBuildCount.withLock { $0 += 1 }
                return WhisperMultipartBody(boundary: "boundary", data: Data())
            }
        }

        #expect(await waitUntil { await permits.waitingCountForTesting == 1 })
        #expect(bodyBuildCount.withLock { $0 } == 0)

        await holderGate.open()
        try await holder.value
        #expect(try await upload.value.text == "hello")
        #expect(bodyBuildCount.withLock { $0 } == 1)
    }

    @Test func chunkProgressStillReportsEveryCompletionInOrder() {
        let updates = Mutex<[OpenAIChunkProgressUpdate]>([])
        var reporter = WhisperChunkProgressReporter(total: 8) { completed, total in
            updates.withLock {
                $0.append(OpenAIChunkProgressUpdate(completed: completed, total: total))
            }
        }

        for _ in 0..<8 {
            reporter.reportCompletion()
        }

        let captured = updates.withLock { $0 }
        #expect(captured.map(\.completed) == Array(1...8))
        #expect(captured.map(\.total) == Array(repeating: 8, count: 8))
    }

    @Test func retryClassificationUsesTypedTransportAndHTTPFailures() {
        #expect(WhisperTranscriber.isRetryableRequestError(AITransportError.requestFailed))
        #expect(
            WhisperTranscriber.isRetryableRequestError(
                AIServiceError.httpError(429, "rate limited")
            )
        )
        #expect(
            WhisperTranscriber.isRetryableRequestError(
                AIServiceError.httpError(500, "unavailable")
            )
        )
        #expect(
            WhisperTranscriber.isRetryableRequestError(
                AIServiceError.httpError(599, "unavailable")
            )
        )
        #expect(
            WhisperTranscriber.isRetryableRequestError(
                AIServiceError.httpError(400, "bad request")
            ) == false
        )
        #expect(
            WhisperTranscriber.isRetryableRequestError(AITransportError.unsafeEndpoint)
                == false
        )
        #expect(
            WhisperTranscriber.isRetryableRequestError(
                AITransportError.bufferedResponseTooLarge
            ) == false
        )
        #expect(
            WhisperTranscriber.isRetryableRequestError(CancellationError()) == false
        )
    }

    private static let validTranscriptResponse = Data(
        """
        {"text":"hello","segments":[],"language":"en","duration":1}
        """.utf8
    )

    private func makeTranscriber(
        client: any OpenAITranscriptionRequesting,
        delays: OpenAIRetryDelayRecorder
    ) -> WhisperTranscriber {
        WhisperTranscriber(
            model: "gpt-4o-transcribe",
            apiClient: client,
            retrySleep: { duration in
                await delays.record(duration)
            }
        )
    }

    private func makeTransport(
        maxBufferedResponseBytes: Int = 1_024
    ) -> HardenedAITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAITranscriptionTestURLProtocol.self]
        return HardenedAITransport(
            configuration: configuration,
            limits: AITransportLimits(
                maxBufferedResponseBytes: maxBufferedResponseBytes,
                maxErrorResponseBytes: 128,
                maxSSETotalBytes: 1,
                maxSSELineBytes: 1,
                maxSSEFrameCount: 1,
                maxStreamDuration: .seconds(600)
            ),
            maximumRequestTimeout: 300
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private actor ScriptedOpenAITranscriptionClient: OpenAITranscriptionRequesting {
    enum Outcome: Sendable {
        case success(Data)
        case http(Int)
        case requestFailed
        case cancelled
    }

    private var outcomes: [Outcome]
    private(set) var requestCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func transcribe(multipartBody: Data, boundary: String) async throws -> Data {
        requestCount += 1
        guard !outcomes.isEmpty else {
            throw AITransportError.requestFailed
        }
        switch outcomes.removeFirst() {
        case .success(let data):
            return data
        case .http(let statusCode):
            throw AIServiceError.httpError(statusCode, "provider failure")
        case .requestFailed:
            throw AITransportError.requestFailed
        case .cancelled:
            throw CancellationError()
        }
    }
}

private actor OpenAIAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int {
        waiters.count
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor OpenAIUploadConcurrencyProbe {
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var requestCount = 0

    func enter() {
        activeCount += 1
        requestCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }
}

private final class ConcurrentOpenAITranscriptionClient: OpenAITranscriptionRequesting {
    private let response: Data
    private let gate: OpenAIAsyncGate
    private let probe: OpenAIUploadConcurrencyProbe

    init(
        response: Data,
        gate: OpenAIAsyncGate,
        probe: OpenAIUploadConcurrencyProbe
    ) {
        self.response = response
        self.gate = gate
        self.probe = probe
    }

    func transcribe(multipartBody: Data, boundary: String) async throws -> Data {
        await probe.enter()
        await gate.wait()
        await probe.leave()
        return response
    }
}

private struct OpenAIChunkProgressUpdate: Sendable {
    let completed: Int
    let total: Int
}

private actor OpenAIRetryDelayRecorder {
    private(set) var values: [Duration] = []

    func record(_ duration: Duration) {
        values.append(duration)
    }
}

private final class OpenAITranscriptionTestURLProtocol: URLProtocol {
    enum Mode: Sendable {
        case success
        case redirect(Int)
        case oversized
        case errorEcho
        case originMismatch
        case hanging
    }

    struct CapturedRequest: Sendable {
        let urlString: String
        let authorization: String?
        let contentType: String?
        let method: String?
        let body: Data?
        let timeoutInterval: TimeInterval
    }

    private struct State: Sendable {
        var mode: Mode = .success
        var capturedRequest: CapturedRequest?
        var requestCountByHost: [String: Int] = [:]
        var authorizationObservedByTarget: String?
        var stopLoadingCount = 0
    }

    private static let state = Mutex(State())

    static var capturedRequest: CapturedRequest? {
        state.withLock { $0.capturedRequest }
    }

    static var authorizationObservedByTarget: String? {
        state.withLock { $0.authorizationObservedByTarget }
    }

    static var totalRequestCount: Int {
        state.withLock { $0.requestCountByHost.values.reduce(0, +) }
    }

    static var stopLoadingCount: Int {
        state.withLock { $0.stopLoadingCount }
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
            if host == "redirect-target.example" {
                state.authorizationObservedByTarget = request.value(
                    forHTTPHeaderField: "Authorization"
                )
            } else {
                state.capturedRequest = CapturedRequest(
                    urlString: url.absoluteString,
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    method: request.httpMethod,
                    body: requestBodyData(),
                    timeoutInterval: request.timeoutInterval
                )
            }
            return state.mode
        }

        if host == "redirect-target.example" {
            send(statusCode: 200, body: Self.successBody, url: url)
            return
        }

        switch mode {
        case .success:
            send(statusCode: 200, body: Self.successBody, url: url)
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
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? "missing"
            send(
                statusCode: 401,
                body: Data(String(repeating: "echo \(authorization) ", count: 32).utf8),
                url: url
            )
        case .originMismatch:
            send(
                statusCode: 200,
                body: Self.successBody,
                url: URL(string: "https://different-origin.example/response")!
            )
        case .hanging:
            break
        }
    }

    override func stopLoading() {
        Self.state.withLock { $0.stopLoadingCount += 1 }
    }

    private static let successBody = Data(
        """
        {"text":"transport protected","segments":[]}
        """.utf8
    )

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
