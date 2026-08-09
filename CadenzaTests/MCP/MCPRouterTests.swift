import Foundation
import Testing
@testable import Cadenza

// MARK: - Stub tool provider

private struct StubTools: MCPToolProviding {
    func toolDefinitions(context: MCPRequestContext) async -> [JSONValue] {
        [.object(["name": "stub_tool", "description": "a stub"])]
    }

    func call(name: String, arguments: JSONValue?, context: MCPRequestContext) async -> MCPToolResult {
        switch name {
        case "boom": return .failure("kaboom")
        case "echo_arg": return .ok(arguments?["value"]?.asString ?? "<none>")
        case "context_echo": return .ok("\(context.clientID):\(context.scopes.map(\.rawValue).sorted().joined(separator: ","))")
        default: return .ok("ok:\(name)")
        }
    }
}

@Suite("MCPRouter")
struct MCPRouterTests {
    private let router = MCPRouter(tools: StubTools(), serverVersion: "1.2.3")

    private func roundTrip(_ json: String) async throws -> JSONValue? {
        guard let data = await router.handle(Data(json.utf8)) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func initializeEchoesProtocolVersion() async throws {
        let response = try await roundTrip(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}")
        let result = response?["result"]
        #expect(result?["protocolVersion"]?.asString == "2025-06-18")
        #expect(result?["serverInfo"]?["name"]?.asString == "Cadenza")
        #expect(result?["serverInfo"]?["version"]?.asString == "1.2.3")
        #expect(result?["capabilities"]?["tools"] != nil)
        #expect(result?["instructions"]?.asString?.isEmpty == false)
    }

    @Test func initializeWithoutVersionUsesLatestSupportedVersion() async throws {
        let response = try await roundTrip("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
        #expect(response?["result"]?["protocolVersion"]?.asString == "2025-06-18")
    }

    @Test func initializeKeepsSupportedLegacyVersion() async throws {
        let response = try await roundTrip(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}")
        #expect(response?["result"]?["protocolVersion"]?.asString == "2025-03-26")
    }

    @Test func initializeUnknownVersionUsesLatestSupportedVersion() async throws {
        let response = try await roundTrip(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\"}}")
        #expect(response?["result"]?["protocolVersion"]?.asString == "2025-06-18")
    }

    @Test func initializedNotificationGetsNoResponse() async throws {
        let response = try await roundTrip("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        #expect(response == nil)
    }

    @Test func unknownNotificationGetsNoResponse() async throws {
        let response = try await roundTrip("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/whatever\"}")
        #expect(response == nil)
    }

    @Test func pingReturnsEmptyResult() async throws {
        let response = try await roundTrip("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}")
        #expect(response?["result"] == .object([:]))
        #expect(response?["id"]?.asInt == 7)
    }

    @Test func toolsListReturnsDefinitions() async throws {
        let response = try await roundTrip("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
        let tools = response?["result"]?["tools"]?.asArray
        #expect(tools?.count == 1)
        #expect(tools?.first?["name"]?.asString == "stub_tool")
    }

    @Test func toolsCallDispatchesAndWrapsResult() async throws {
        let response = try await roundTrip(
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo_arg\",\"arguments\":{\"value\":\"hi\"}}}")
        let result = response?["result"]
        #expect(result?["isError"]?.asBool == false)
        #expect(result?["content"]?.asArray?.first?["text"]?.asString == "hi")
    }

    @Test func toolFailureStaysToolLevel() async throws {
        let response = try await roundTrip(
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"boom\"}}")
        #expect(response?["error"] == nil)  // NOT a protocol error
        #expect(response?["result"]?["isError"]?.asBool == true)
    }

    @Test func requestContextIsForwardedToToolProvider() async throws {
        let context = MCPRequestContext(
            clientID: "codex",
            clientName: "Codex",
            scopes: [.recordingRead],
            isLegacy: false
        )
        let body = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"context_echo"}}"#.utf8)
        let data = try #require(await router.handle(body, context: context))
        let response = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(response["result"]?["content"]?.asArray?.first?["text"]?.asString == "codex:recording.read")
    }

    @Test func toolsCallMissingNameIsInvalidParams() async throws {
        let response = try await roundTrip("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{}}")
        #expect(response?["error"]?["code"]?.asInt == JSONRPC.invalidParams)
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let response = try await roundTrip("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/list\"}")
        #expect(response?["error"]?["code"]?.asInt == JSONRPC.methodNotFound)
    }

    @Test func malformedJSONIsParseError() async throws {
        let response = try await roundTrip("{nope")
        #expect(response?["error"]?["code"]?.asInt == JSONRPC.parseError)
        #expect(response?["id"] == .null)
    }

    @Test func batchIsRejected() async throws {
        let response = try await roundTrip("  [{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]")
        #expect(response?["error"]?["code"]?.asInt == JSONRPC.invalidRequest)
    }
}
