import Foundation
import Network
import os.lock
import Testing
@testable import Cadenza

// MARK: - Helpers

private struct HTTPStubTools: MCPToolProviding {
    func toolDefinitions(context: MCPRequestContext) async -> [JSONValue] {
        [.object(["name": "stub_tool"])]
    }
    func call(name: String, arguments: JSONValue?, context: MCPRequestContext) async -> MCPToolResult {
        .ok("ok:\(name)")
    }
}

private final class HTTPMemoryTokenPersistence: MCPTokenPersisting, Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [String: String]())
    func get(_ key: String) -> String? { values.withLock { $0[key] } }
    func set(_ value: String, forKey key: String) throws { values.withLock { $0[key] = value } }
    func remove(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

/// Boots a server on an ephemeral port and tears it down per test.
private final class ServerHarness: Sendable {
    let server: MCPServer
    let port: UInt16
    let token = "test-token-0123456789abcdef"

    private init(server: MCPServer, port: UInt16) {
        self.server = server
        self.port = port
    }

    static func start(
        accessStore: MCPClientAccessStore = .shared,
        tools: any MCPToolProviding = HTTPStubTools()
    ) async throws -> ServerHarness {
        let server = MCPServer()
        let router = MCPRouter(tools: tools, serverVersion: "test")
        let token = "test-token-0123456789abcdef"
        await server.start(
            port: 0,
            token: token,
            router: router,
            accessStore: accessStore,
            onStatus: { _ in }
        )

        // Poll until running (listener readiness is asynchronous).
        for _ in 0..<100 {
            if case .running(let port) = await server.status {
                return ServerHarness(server: server, port: port)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let status = await server.status
        throw HarnessError.notRunning(String(describing: status))
    }

    enum HarnessError: Error { case notRunning(String) }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }

    func request(body: String, token: String? = nil, method: String = "POST",
                 path: String = "/mcp", origin: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    func stop() async {
        await server.stop()
    }
}

/// Raw TCP client for malformed/fragmented requests URLSession can't produce.
private final class RawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.rawclient")

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
    }

    func send(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    /// Read until the peer closes; returns everything received.
    func readToEnd() async -> String {
        var collected = Data()
        while true {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete || error != nil {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            guard let chunk else { break }
            collected.append(chunk)
        }
        connection.cancel()
        return String(data: collected, encoding: .utf8) ?? ""
    }

    func close() {
        connection.cancel()
    }
}

private func waitForConnectionCount(
    _ expectedCount: Int,
    on server: MCPServer,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await server.activeConnectionCount == expectedCount { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await server.activeConnectionCount == expectedCount
}

/// Tool provider whose call blocks on an externally released gate, so a
/// test can hold a real router handler in flight across stopAndWait.
private struct LatchedTools: MCPToolProviding {
    let onEnter: @Sendable () -> Void
    let gate: AsyncStream<Void>

    func toolDefinitions(context: MCPRequestContext) async -> [JSONValue] {
        [.object(["name": "latched_tool"])]
    }

    func call(name: String, arguments: JSONValue?, context: MCPRequestContext) async -> MCPToolResult {
        onEnter()
        for await _ in gate { break }
        return .ok("released:\(name)")
    }
}

// MARK: - Pure validation helpers

@Suite("MCPHTTPValidation")
struct MCPHTTPValidationTests {

    @Test func hostAllowlist() {
        #expect(MCPHTTPConnection.isAllowedHost("127.0.0.1:8585", expectedPort: 8585))
        #expect(MCPHTTPConnection.isAllowedHost("localhost:8585", expectedPort: 8585))
        #expect(MCPHTTPConnection.isAllowedHost("LOCALHOST:8585", expectedPort: 8585))
        #expect(MCPHTTPConnection.isAllowedHost("127.0.0.1", expectedPort: 8585))
        #expect(MCPHTTPConnection.isAllowedHost("[::1]:8585", expectedPort: 8585))
        #expect(MCPHTTPConnection.isAllowedHost("[::1]", expectedPort: 8585))
        #expect(!MCPHTTPConnection.isAllowedHost("evil.com:8585", expectedPort: 8585))
        #expect(!MCPHTTPConnection.isAllowedHost("127.0.0.1.evil.com:8585", expectedPort: 8585))
        #expect(!MCPHTTPConnection.isAllowedHost("127.0.0.1:9999", expectedPort: 8585))  // wrong port
        #expect(!MCPHTTPConnection.isAllowedHost(nil, expectedPort: 8585))
        #expect(!MCPHTTPConnection.isAllowedHost("", expectedPort: 8585))
    }

    @Test func originAllowlist() {
        #expect(MCPHTTPConnection.isAllowedOrigin(nil))  // non-browser clients
        #expect(MCPHTTPConnection.isAllowedOrigin("http://localhost:3000"))
        #expect(MCPHTTPConnection.isAllowedOrigin("http://127.0.0.1"))
        #expect(!MCPHTTPConnection.isAllowedOrigin("https://evil.com"))
        #expect(!MCPHTTPConnection.isAllowedOrigin("null"))
        #expect(!MCPHTTPConnection.isAllowedOrigin("file:///etc/passwd"))
    }

    @Test func tokenComparison() {
        #expect(MCPHTTPConnection.tokenMatches(authorizationHeader: "Bearer abc", expected: "abc"))
        #expect(MCPHTTPConnection.tokenMatches(authorizationHeader: "bearer abc", expected: "abc"))
        #expect(!MCPHTTPConnection.tokenMatches(authorizationHeader: "Bearer abd", expected: "abc"))
        #expect(!MCPHTTPConnection.tokenMatches(authorizationHeader: "Basic abc", expected: "abc"))
        #expect(!MCPHTTPConnection.tokenMatches(authorizationHeader: nil, expected: "abc"))
    }

    @Test func headParsing() {
        let head = MCPHTTPConnection.parseHead(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8585\r\nContent-Length: 42\r\nAuthorization: Bearer x")
        #expect(head?.method == "POST")
        #expect(head?.path == "/mcp")
        #expect(head?.headers["host"] == "127.0.0.1:8585")
        #expect(head?.headers["content-length"] == "42")
        #expect(MCPHTTPConnection.parseHead("garbage") == nil)
    }
}

// MARK: - Live server tests

@Suite("MCPHTTPServer", .serialized)
struct MCPHTTPServerTests {

    private let toolsListBody = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#

    @Test func happyPathToolsList() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.request(body: toolsListBody, token: harness.token)
        #expect(status == 200)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["result"]?["tools"]?.asArray?.first?["name"]?.asString == "stub_tool")
    }

    @Test func fragmentedRequestStillParses() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let body = toolsListBody
        let request = "POST /mcp HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(harness.port)\r\n"
            + "Authorization: Bearer \(harness.token)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n"
            + body

        // Split mid-header and mid-body, with delays — simulates TCP
        // fragmentation that breaks single-receive parsers.
        let cuts = [request.count / 3, 2 * request.count / 3]
        let part1 = String(request.prefix(cuts[0]))
        let part2 = String(request.dropFirst(cuts[0]).prefix(cuts[1] - cuts[0]))
        let part3 = String(request.dropFirst(cuts[1]))

        let client = RawClient(port: harness.port)
        await client.send(part1)
        try await Task.sleep(for: .milliseconds(50))
        await client.send(part2)
        try await Task.sleep(for: .milliseconds(50))
        await client.send(part3)

        let response = await client.readToEnd()
        #expect(response.contains("200 OK"))
        #expect(response.contains("stub_tool"))
        #expect(response.contains("Connection: close"))
    }

    @Test func missingTokenIs401() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let (noToken, _) = try await harness.request(body: toolsListBody, token: nil)
        #expect(noToken == 401)
        let (badToken, _) = try await harness.request(body: toolsListBody, token: "wrong")
        #expect(badToken == 401)
    }

    @Test func perClientTokenAuthenticatesWithoutReplacingLegacyToken() async throws {
        let suite = "mcp-http-access-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let accessStore = MCPClientAccessStore(
            keychain: HTTPMemoryTokenPersistence(),
            defaultsSuiteName: suite,
            metadataKey: "records",
            tokenPrefix: "tokens."
        )
        let clientToken = try accessStore.token(
            for: "codex",
            name: "Codex",
            scopes: [.recordingRead]
        )
        let harness = try await ServerHarness.start(accessStore: accessStore)
        defer { Task { await harness.stop() } }

        let (clientStatus, _) = try await harness.request(body: toolsListBody, token: clientToken)
        let (legacyStatus, _) = try await harness.request(body: toolsListBody, token: harness.token)
        #expect(clientStatus == 200)
        #expect(legacyStatus == 200)

        #expect(accessStore.revoke(clientID: "codex"))
        let (revokedStatus, _) = try await harness.request(body: toolsListBody, token: clientToken)
        #expect(revokedStatus == 401)
    }

    @Test func evilOriginIs403() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let (status, _) = try await harness.request(body: toolsListBody, token: harness.token,
                                                    origin: "https://evil.com")
        #expect(status == 403)
    }

    @Test func evilHostIs403() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let client = RawClient(port: harness.port)
        await client.send("POST /mcp HTTP/1.1\r\nHost: evil.com\r\nAuthorization: Bearer \(harness.token)\r\nContent-Length: 2\r\n\r\n{}")
        let response = await client.readToEnd()
        #expect(response.contains("403"))
    }

    @Test func wrongMethodAndPath() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let (getStatus, _) = try await harness.request(body: "", token: harness.token, method: "GET")
        #expect(getStatus == 405)
        let (pathStatus, _) = try await harness.request(body: toolsListBody, token: harness.token,
                                                        path: "/other")
        #expect(pathStatus == 404)
    }

    @Test func missingContentLengthIs411() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let client = RawClient(port: harness.port)
        await client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\nAuthorization: Bearer \(harness.token)\r\n\r\n")
        let response = await client.readToEnd()
        #expect(response.contains("411"))
    }

    @Test func oversizedBodyIs413() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let client = RawClient(port: harness.port)
        await client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\nAuthorization: Bearer \(harness.token)\r\nContent-Length: 2097152\r\n\r\n")
        let response = await client.readToEnd()
        #expect(response.contains("413"))
    }

    @Test func notificationGets202() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        let (status, data) = try await harness.request(
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, token: harness.token)
        #expect(status == 202)
        #expect(data.isEmpty)
    }

    @Test func concurrentConnections() async throws {
        let harness = try await ServerHarness.start()
        defer { Task { await harness.stop() } }

        async let first = harness.request(body: toolsListBody, token: harness.token)
        async let second = harness.request(
            body: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: harness.token)
        let (status1, _) = try await first
        let (status2, data2) = try await second
        #expect(status1 == 200)
        #expect(status2 == 200)
        let json = try JSONDecoder().decode(JSONValue.self, from: data2)
        #expect(json["result"] == .object([:]))
    }

    @Test func idleUnauthenticatedConnectionsAreBoundedAndCapacityRecovers() async throws {
        let harness = try await ServerHarness.start()
        var heldConnections = (0..<MCPServer.Constants.maxConcurrentConnections).map { _ in
            RawClient(port: harness.port)
        }
        defer {
            for connection in heldConnections { connection.close() }
            Task { await harness.stop() }
        }

        #expect(
            await waitForConnectionCount(
                MCPServer.Constants.maxConcurrentConnections,
                on: harness.server
            )
        )

        let overflow = RawClient(port: harness.port)
        defer { overflow.close() }
        let clock = ContinuousClock()
        let rejectionStarted = clock.now
        let overflowResponse = await overflow.readToEnd()
        let rejectionDuration = rejectionStarted.duration(to: clock.now)

        #expect(overflowResponse.isEmpty)
        #expect(rejectionDuration < .seconds(2))
        #expect(
            await harness.server.activeConnectionCount
                == MCPServer.Constants.maxConcurrentConnections
        )

        heldConnections.removeLast().close()
        #expect(
            await waitForConnectionCount(
                MCPServer.Constants.maxConcurrentConnections - 1,
                on: harness.server
            )
        )

        let (status, _) = try await harness.request(
            body: toolsListBody,
            token: harness.token
        )
        #expect(status == 200)
    }

    @Test func stopRefusesNewConnections() async throws {
        let harness = try await ServerHarness.start()
        await harness.stop()

        do {
            _ = try await harness.request(body: toolsListBody, token: harness.token)
            Issue.record("Expected connection failure after stop()")
        } catch {
            // Connection refused — expected.
        }
    }
}

// MARK: - Drain barrier against live connection handlers

@Suite("MCPServerDrain", .serialized)
struct MCPServerDrainTests {
    private let callBody =
        #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"latched_tool"}}"#

    private func makeLatch() -> (
        tools: LatchedTools,
        entered: AsyncStream<Void>,
        release: AsyncStream<Void>.Continuation
    ) {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let tools = LatchedTools(
            onEnter: { enteredContinuation.yield() },
            gate: gate
        )
        return (tools, entered, gateContinuation)
    }

    /// stopAndWait must report false while a real router handler is
    /// still inside a tracked connection task — connectionTasks provably
    /// tracks router.handle, not just the socket lifecycle.
    @Test func stopAndWaitTimesOutWhileHandlerHeld() async throws {
        let latch = makeLatch()
        let harness = try await ServerHarness.start(tools: latch.tools)

        let request = Task {
            try? await harness.request(body: callBody, token: harness.token)
        }
        var iterator = latch.entered.makeAsyncIterator()
        _ = await iterator.next()

        let drained = await harness.server.stopAndWait(timeout: .milliseconds(200))
        #expect(!drained)

        latch.release.finish()
        _ = await request.value
    }

    /// The same held handler drains successfully once released before
    /// the bound expires.
    @Test func stopAndWaitDrainsAfterHandlerReleases() async throws {
        let latch = makeLatch()
        let harness = try await ServerHarness.start(tools: latch.tools)

        let request = Task {
            try? await harness.request(body: callBody, token: harness.token)
        }
        var iterator = latch.entered.makeAsyncIterator()
        _ = await iterator.next()

        let drain = Task {
            await harness.server.stopAndWait(timeout: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        latch.release.finish()
        #expect(await drain.value)
        _ = await request.value
    }
}
