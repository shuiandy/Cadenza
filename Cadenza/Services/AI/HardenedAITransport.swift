import Darwin
import Foundation

// MARK: - Limits and errors

struct AITransportLimits: Sendable {
    static let standard = AITransportLimits(
        maxBufferedResponseBytes: 8 * 1_024 * 1_024,
        maxErrorResponseBytes: 2 * 1_024,
        maxSSETotalBytes: 16 * 1_024 * 1_024,
        maxSSELineBytes: 256 * 1_024,
        maxSSEFrameCount: 100_000,
        maxStreamDuration: .seconds(300)
    )

    static let modelList = AITransportLimits(
        maxBufferedResponseBytes: 2 * 1_024 * 1_024,
        maxErrorResponseBytes: 2 * 1_024,
        maxSSETotalBytes: 1,
        maxSSELineBytes: 1,
        maxSSEFrameCount: 1,
        maxStreamDuration: .seconds(60)
    )

    static let transcription = AITransportLimits(
        maxBufferedResponseBytes: 8 * 1_024 * 1_024,
        maxErrorResponseBytes: 2 * 1_024,
        maxSSETotalBytes: 1,
        maxSSELineBytes: 1,
        maxSSEFrameCount: 1,
        maxStreamDuration: .seconds(600)
    )

    static let ephemeralToken = AITransportLimits(
        maxBufferedResponseBytes: 64 * 1_024,
        maxErrorResponseBytes: 2 * 1_024,
        maxSSETotalBytes: 1,
        maxSSELineBytes: 1,
        maxSSEFrameCount: 1,
        maxStreamDuration: .seconds(10)
    )

    let maxBufferedResponseBytes: Int
    let maxErrorResponseBytes: Int
    let maxSSETotalBytes: Int
    let maxSSELineBytes: Int
    let maxSSEFrameCount: Int
    let maxStreamDuration: Duration
}

enum AITransportError: Error, LocalizedError {
    case unsafeEndpoint
    case responseOriginMismatch
    case invalidHTTPResponse
    case bufferedResponseTooLarge
    case streamResponseTooLarge
    case streamLineTooLarge
    case streamFrameLimitExceeded
    case streamDeadlineExceeded
    case invalidStreamEncoding
    case modelListItemLimitExceeded
    case invalidModelIdentifier
    case requestFailed

    // Transport errors flow into chat, summary, model-list, and transcription
    // alerts as Text(String). Collapse implementation details into stable,
    // actionable localized categories at this boundary.
    var errorDescription: String? { localizedMessage() }

    func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .unsafeEndpoint, .responseOriginMismatch:
            return LocalizedBundle.string(
                "The AI provider connection was blocked for security. Check the provider endpoint in Settings.",
                locale: locale
            )
        case .invalidHTTPResponse, .invalidStreamEncoding, .invalidModelIdentifier:
            return LocalizedBundle.string(
                "The AI provider returned an invalid response. Try again or choose another provider in Settings.",
                locale: locale
            )
        case .bufferedResponseTooLarge, .streamResponseTooLarge, .streamLineTooLarge,
             .streamFrameLimitExceeded, .modelListItemLimitExceeded:
            return LocalizedBundle.string(
                "The AI provider response was too large to process. Try again with less content or choose another provider.",
                locale: locale
            )
        case .streamDeadlineExceeded:
            return LocalizedBundle.string(
                "The AI provider took too long to respond. Check your network connection and try again.",
                locale: locale
            )
        case .requestFailed:
            return LocalizedBundle.string(
                "The AI provider request failed. Check your API key, provider status, and network connection.",
                locale: locale
            )
        }
    }
}

// MARK: - Endpoint policy

struct AIEndpointOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int
}

enum AIEndpointPolicy {
    static func validate(_ url: URL, provider: AIProvider?) throws -> AIEndpointOrigin {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty,
              url.port == nil || url.port == 443 else {
            throw AITransportError.unsafeEndpoint
        }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host.contains("."),
              !host.hasSuffix("."),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.contains("%"),
              !resemblesIPv4Literal(host),
              !isIPAddressLiteral(host) else {
            throw AITransportError.unsafeEndpoint
        }

        let origin = AIEndpointOrigin(scheme: "https", host: host, port: 443)
        if provider == .minimax {
            let miniMaxOrigin = AIEndpointOrigin(scheme: "https", host: "api.minimax.io", port: 443)
            guard origin == miniMaxOrigin else {
                throw AITransportError.unsafeEndpoint
            }
        }
        return origin
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
        var ipv4 = in_addr()
        let isIPv4 = host.withCString { address in
            inet_pton(AF_INET, address, &ipv4) == 1
        }
        if isIPv4 {
            return true
        }

        var ipv6 = in6_addr()
        return host.withCString { address in
            inet_pton(AF_INET6, address, &ipv6) == 1
        }
    }

    private static func resemblesIPv4Literal(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else {
            return false
        }
        return components.allSatisfy { component in
            guard !component.isEmpty else { return false }
            if component.hasPrefix("0x") || component.hasPrefix("0X") {
                let digits = component.dropFirst(2)
                return !digits.isEmpty && digits.utf8.allSatisfy { byte in
                    (0x30...0x39).contains(byte)
                        || (0x41...0x46).contains(byte)
                        || (0x61...0x66).contains(byte)
                }
            }
            return component.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
    }
}

// MARK: - Clock and SSE parser

struct AITransportClock: Sendable {
    static let continuous: AITransportClock = {
        let clock = ContinuousClock()
        let origin = clock.now
        return AITransportClock(now: { origin.duration(to: clock.now) })
    }()

    let now: @Sendable () -> Duration
}

struct BoundedSSEParser {
    private let limits: AITransportLimits
    private let clock: AITransportClock
    private let startedAt: Duration
    private var totalByteCount = 0
    private var frameCount = 0
    private var line = Data()
    private var frameDataLines: [String] = []
    private var previousByteWasCarriageReturn = false

    init(limits: AITransportLimits, clock: AITransportClock = .continuous) {
        self.limits = limits
        self.clock = clock
        self.startedAt = clock.now()
    }

    mutating func consume(byte: UInt8) throws -> String? {
        try checkDeadline()
        totalByteCount += 1
        guard totalByteCount <= limits.maxSSETotalBytes else {
            throw AITransportError.streamResponseTooLarge
        }

        if byte == 0x0A, previousByteWasCarriageReturn {
            previousByteWasCarriageReturn = false
            return nil
        }
        previousByteWasCarriageReturn = false

        if byte == 0x0D {
            previousByteWasCarriageReturn = true
            return try finishLine()
        }
        if byte == 0x0A {
            return try finishLine()
        }

        guard line.count < limits.maxSSELineBytes else {
            throw AITransportError.streamLineTooLarge
        }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> String? {
        try checkDeadline()
        if !line.isEmpty {
            if let payload = try finishLine() {
                return payload
            }
        }
        return try finishFrame()
    }

    private mutating func finishLine() throws -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            return try finishFrame()
        }
        guard let decodedLine = String(data: line, encoding: .utf8) else {
            throw AITransportError.invalidStreamEncoding
        }
        guard !decodedLine.hasPrefix(":"),
              let colon = decodedLine.firstIndex(of: ":"),
              decodedLine[..<colon] == "data" else {
            return nil
        }

        var value = decodedLine[decodedLine.index(after: colon)...]
        if value.first == " " {
            value = value.dropFirst()
        }
        frameDataLines.append(String(value))
        return nil
    }

    private mutating func finishFrame() throws -> String? {
        guard !frameDataLines.isEmpty else {
            return nil
        }
        frameCount += 1
        guard frameCount <= limits.maxSSEFrameCount else {
            throw AITransportError.streamFrameLimitExceeded
        }
        defer { frameDataLines.removeAll(keepingCapacity: true) }
        return frameDataLines.joined(separator: "\n")
    }

    private func checkDeadline() throws {
        guard clock.now() - startedAt <= limits.maxStreamDuration else {
            throw AITransportError.streamDeadlineExceeded
        }
    }
}

// MARK: - URLSession transport

struct HardenedAITransport: Sendable {
    static let shared = HardenedAITransport()
    static let modelList = HardenedAITransport(limits: .modelList)
    static let transcription = HardenedAITransport(
        configuration: makeConfiguration(
            requestTimeout: 300,
            resourceTimeout: 600
        ),
        limits: .transcription,
        maximumRequestTimeout: 300
    )
    static let ephemeralToken = HardenedAITransport(
        configuration: makeConfiguration(
            requestTimeout: 10,
            resourceTimeout: 10
        ),
        limits: .ephemeralToken,
        maximumRequestTimeout: 10
    )

    private let session: URLSession
    private let limits: AITransportLimits
    private let clock: AITransportClock

    init(
        configuration: URLSessionConfiguration = HardenedAITransport.makeConfiguration(),
        limits: AITransportLimits = .standard,
        clock: AITransportClock = .continuous,
        maximumRequestTimeout: TimeInterval = 30
    ) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = min(
            configuration.timeoutIntervalForRequest,
            max(1, maximumRequestTimeout)
        )
        configuration.timeoutIntervalForResource = min(
            configuration.timeoutIntervalForResource,
            max(1, Self.seconds(limits.maxStreamDuration))
        )
        self.session = URLSession(
            configuration: configuration,
            delegate: AIRedirectRejectingSessionDelegate(),
            delegateQueue: nil
        )
        self.limits = limits
        self.clock = clock
    }

    func data(
        for request: URLRequest,
        provider: AIProvider? = nil,
        redacting secrets: [String] = []
    ) async throws -> Data {
        do {
            return try await performData(for: request, provider: provider, redacting: secrets)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AITransportError {
            throw error
        } catch let error as AIServiceError {
            throw error
        } catch {
            throw AITransportError.requestFailed
        }
    }

    private func performData(
        for request: URLRequest,
        provider: AIProvider?,
        redacting secrets: [String]
    ) async throws -> Data {
        let expectedOrigin = try validatedOrigin(
            for: request,
            provider: provider,
            secrets: secrets
        )
        let (bytes, response) = try await session.bytes(for: request)
        let http = try validatedResponse(response, expectedOrigin: expectedOrigin, provider: provider)

        if !(200..<300).contains(http.statusCode) {
            let errorData = try await collect(
                bytes,
                maximumByteCount: limits.maxErrorResponseBytes,
                truncateAtLimit: true
            )
            let message = Self.sanitizedErrorMessage(
                data: errorData,
                statusCode: http.statusCode,
                secrets: secrets
            )
            throw AIServiceError.httpError(http.statusCode, message)
        }

        if http.expectedContentLength > Int64(limits.maxBufferedResponseBytes) {
            throw AITransportError.bufferedResponseTooLarge
        }
        return try await collect(
            bytes,
            maximumByteCount: limits.maxBufferedResponseBytes,
            truncateAtLimit: false
        )
    }

    func serverSentEvents(
        for request: URLRequest,
        provider: AIProvider? = nil,
        redacting secrets: [String] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let expectedOrigin = try validatedOrigin(
                        for: request,
                        provider: provider,
                        secrets: secrets
                    )
                    var parser = BoundedSSEParser(limits: limits, clock: clock)
                    let (bytes, response) = try await session.bytes(for: request)
                    let http = try validatedResponse(
                        response,
                        expectedOrigin: expectedOrigin,
                        provider: provider
                    )

                    if !(200..<300).contains(http.statusCode) {
                        let errorData = try await collect(
                            bytes,
                            maximumByteCount: limits.maxErrorResponseBytes,
                            truncateAtLimit: true
                        )
                        let message = Self.sanitizedErrorMessage(
                            data: errorData,
                            statusCode: http.statusCode,
                            secrets: secrets
                        )
                        throw AIServiceError.httpError(http.statusCode, message)
                    }
                    if http.expectedContentLength > Int64(limits.maxSSETotalBytes) {
                        throw AITransportError.streamResponseTooLarge
                    }

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let payload = try parser.consume(byte: byte) {
                            guard case .enqueued = continuation.yield(payload) else {
                                throw CancellationError()
                            }
                        }
                    }
                    if let payload = try parser.finish() {
                        _ = continuation.yield(payload)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as AITransportError {
                    continuation.finish(throwing: error)
                } catch let error as AIServiceError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AITransportError.requestFailed)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func validatedOrigin(
        for request: URLRequest,
        provider: AIProvider?,
        secrets: [String]
    ) throws -> AIEndpointOrigin {
        guard let url = request.url else {
            throw AITransportError.unsafeEndpoint
        }
        guard !Self.url(url, containsAny: secrets) else {
            throw AITransportError.unsafeEndpoint
        }
        return try AIEndpointPolicy.validate(url, provider: provider)
    }

    private func validatedResponse(
        _ response: URLResponse,
        expectedOrigin: AIEndpointOrigin,
        provider: AIProvider?
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url else {
            throw AITransportError.invalidHTTPResponse
        }
        let finalOrigin = try AIEndpointPolicy.validate(finalURL, provider: provider)
        guard finalOrigin == expectedOrigin else {
            throw AITransportError.responseOriginMismatch
        }
        return http
    }

    private func collect(
        _ bytes: URLSession.AsyncBytes,
        maximumByteCount: Int,
        truncateAtLimit: Bool
    ) async throws -> Data {
        var result = Data()
        result.reserveCapacity(min(maximumByteCount, 64 * 1_024))
        for try await byte in bytes {
            if result.count == maximumByteCount {
                if truncateAtLimit {
                    break
                }
                throw AITransportError.bufferedResponseTooLarge
            }
            result.append(byte)
        }
        return result
    }

    private static func sanitizedErrorMessage(
        data: Data,
        statusCode: Int,
        secrets: [String]
    ) -> String {
        var text = String(decoding: data, as: UTF8.self)
        for secret in secrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               encoded != secret {
                text = text.replacingOccurrences(of: encoded, with: "[REDACTED]")
            }
        }
        return text.isEmpty ? "HTTP \(statusCode)" : text
    }

    private static func url(_ url: URL, containsAny secrets: [String]) -> Bool {
        let absoluteString = url.absoluteString
        let queryComponentAllowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        for secret in secrets where !secret.isEmpty {
            if absoluteString.contains(secret) {
                return true
            }
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: queryComponentAllowed),
               absoluteString.contains(encoded) {
                return true
            }
        }
        return false
    }

    private static func makeConfiguration(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 300
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private final class AIRedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
