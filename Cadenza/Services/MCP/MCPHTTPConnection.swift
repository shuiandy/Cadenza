import CryptoKit
import Foundation
import Network

/// One HTTP/1.1 exchange on the MCP endpoint.
///
/// Deliberately NOT modeled on `OAuthCallbackServer`: its single
/// `receive(maximumLength: 4096)` only survives body-less GETs. MCP is
/// JSON-RPC over POST and TCP fragments around 1.4 KB, so even a 2 KB request
/// can arrive in two segments. This actor accumulates a buffer until the
/// header block is complete, then reads exactly `Content-Length` body bytes.
///
/// Every response carries `Connection: close` — no keep-alive state machine;
/// reconnect cost is irrelevant on loopback and universally supported.
actor MCPHTTPConnection {
    struct Config: Sendable {
        let authenticate: @Sendable (String) -> MCPRequestContext?
        let expectedPort: UInt16
        let path: String
        let maxHeaderBytes: Int
        let maxBodyBytes: Int
        let idleTimeout: Duration
    }

    private let connection: NWConnection
    private let config: Config
    private let handler: @Sendable (Data, MCPRequestContext) async -> Data?
    private let onClosed: @Sendable (ObjectIdentifier) -> Void

    private static let queue = DispatchQueue(label: "com.shuiandy.Cadenza.mcp-http")

    init(connection: NWConnection,
         config: Config,
         handler: @escaping @Sendable (Data, MCPRequestContext) async -> Data?,
         onClosed: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.config = config
        self.handler = handler
        self.onClosed = onClosed
    }

    /// Serve exactly one request, respond, close.
    func run() async {
        let watchdog = Task { [connection, config] in
            try? await Task.sleep(for: config.idleTimeout)
            if !Task.isCancelled { connection.cancel() }
        }
        defer {
            watchdog.cancel()
            connection.cancel()
            onClosed(ObjectIdentifier(connection))
        }

        connection.start(queue: Self.queue)
        do {
            try await serve()
        } catch {
            // Peer vanished or watchdog fired — nothing useful to send.
        }
    }

    func shutdown() {
        connection.cancel()
    }

    // MARK: - Request lifecycle

    private func serve() async throws {
        var buffer = Data()
        let headerEnd = Data("\r\n\r\n".utf8)

        // 1. Accumulate until the full header block has arrived.
        var headerRange = buffer.range(of: headerEnd)
        while headerRange == nil {
            guard buffer.count <= config.maxHeaderBytes else {
                await send(status: 431, reason: "Request Header Fields Too Large",
                           body: Self.errorBody("Header block exceeds \(config.maxHeaderBytes) bytes"))
                return
            }
            guard let chunk = try await receiveChunk() else { return }  // peer closed early
            buffer.append(chunk)
            headerRange = buffer.range(of: headerEnd)
        }

        guard let headerRange,
              let headText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8),
              let head = Self.parseHead(headText) else {
            await send(status: 400, reason: "Bad Request", body: Self.errorBody("Malformed request head"))
            return
        }

        // 2. Routing & validation. Order: path → method → host/origin → auth → framing.
        guard head.path == config.path else {
            await send(status: 404, reason: "Not Found", body: Self.errorBody("Unknown path; MCP endpoint is \(config.path)"))
            return
        }
        guard head.method == "POST" else {
            await send(status: 405, reason: "Method Not Allowed",
                       body: Self.errorBody("Only POST is supported (no SSE stream is offered)"))
            return
        }
        guard Self.isAllowedHost(head.headers["host"], expectedPort: config.expectedPort),
              Self.isAllowedOrigin(head.headers["origin"]) else {
            await send(status: 403, reason: "Forbidden", body: Self.errorBody("Host or Origin not allowed"))
            return
        }
        guard let presentedToken = Self.bearerToken(from: head.headers["authorization"]),
              let requestContext = config.authenticate(presentedToken) else {
            await send(status: 401, reason: "Unauthorized", body: Self.errorBody("Missing or invalid bearer token"))
            return
        }
        guard let lengthText = head.headers["content-length"], let contentLength = Int(lengthText), contentLength >= 0 else {
            await send(status: 411, reason: "Length Required", body: Self.errorBody("Content-Length is required"))
            return
        }
        guard contentLength <= config.maxBodyBytes else {
            await send(status: 413, reason: "Content Too Large",
                       body: Self.errorBody("Body exceeds \(config.maxBodyBytes) bytes"))
            return
        }

        // 3. Read the body to exactly Content-Length.
        var body = Data(buffer[headerRange.upperBound...])
        while body.count < contentLength {
            guard let chunk = try await receiveChunk() else { return }
            body.append(chunk)
        }
        body = body.prefix(contentLength)

        // 4. Dispatch. nil ⇒ notification ⇒ 202 with empty body.
        if let response = await handler(body, requestContext) {
            await send(status: 200, reason: "OK", body: response)
        } else {
            await send(status: 202, reason: "Accepted", body: Data())
        }
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(status: Int, reason: String, body: Data) async {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: payload, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private static func errorBody(_ message: String) -> Data {
        JSONRPC.encode(.object(["error": .string(message)]))
    }

    // MARK: - Pure validation helpers (unit-tested directly)

    struct ParsedHead {
        let method: String
        let path: String
        let headers: [String: String]  // keys lowercased
    }

    static func parseHead(_ text: String) -> ParsedHead? {
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return ParsedHead(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }

    /// DNS-rebinding guard: Host must be loopback, and when it carries a port
    /// it must be OUR port.
    static func isAllowedHost(_ rawHost: String?, expectedPort: UInt16) -> Bool {
        guard var host = rawHost?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") {  // [::1] or [::1]:port
            guard let close = host.firstIndex(of: "]") else { return false }
            let address = String(host[host.index(after: host.startIndex)..<close])
            let rest = host[host.index(after: close)...]
            if rest.hasPrefix(":") {
                guard UInt16(rest.dropFirst()) == expectedPort else { return false }
            } else if !rest.isEmpty {
                return false
            }
            return address == "::1"
        }
        if let colon = host.lastIndex(of: ":") {
            guard UInt16(host[host.index(after: colon)...]) == expectedPort else { return false }
            host = String(host[..<colon])
        }
        return host == "127.0.0.1" || host == "localhost"
    }

    /// Absent Origin (non-browser client) passes; present Origin must be a
    /// loopback web origin. "null" and anything else is rejected.
    static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Constant-time comparison via SHA-256 digests — avoids both timing
    /// leaks and length leaks.
    static func tokenMatches(authorizationHeader: String?, expected: String) -> Bool {
        guard let presented = bearerToken(from: authorizationHeader) else { return false }
        let presentedDigest = SHA256.hash(data: Data(presented.utf8))
        let expectedDigest = SHA256.hash(data: Data(expected.utf8))
        return presentedDigest == expectedDigest
    }

    static func bearerToken(from authorizationHeader: String?) -> String? {
        guard let header = authorizationHeader else { return nil }
        let prefix = "bearer "
        guard header.lowercased().hasPrefix(prefix) else { return nil }
        let token = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
