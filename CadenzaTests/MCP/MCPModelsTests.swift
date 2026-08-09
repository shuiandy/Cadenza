import Foundation
import Testing
@testable import Cadenza

@Suite("MCPModels")
struct MCPModelsTests {

    @Test func jsonValueRoundTrip() throws {
        let original: JSONValue = [
            "string": "hello",
            "int": 42,
            "double": 3.5,
            "bool": true,
            "null": nil,
            "array": [1, "two", false],
            "nested": ["inner": ["deep": "value"]],
        ]
        let data = JSONRPC.encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test func jsonValueAccessors() {
        let value: JSONValue = ["count": 7, "ratio": 0.5, "name": "x", "on": true]
        #expect(value["count"]?.asInt == 7)
        #expect(value["count"]?.asDouble == 7.0)
        #expect(value["ratio"]?.asInt == nil)  // fractional → not an Int
        #expect(value["ratio"]?.asDouble == 0.5)
        #expect(value["name"]?.asString == "x")
        #expect(value["on"]?.asBool == true)
        #expect(value["missing"] == nil)
    }

    @Test func boolDoesNotDecodeAsNumber() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("{\"flag\": true}".utf8))
        #expect(decoded["flag"] == .bool(true))
        #expect(decoded["flag"]?.asInt == nil)
    }

    @Test func requestDecodingNumberID() throws {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.id == .number(1))
        #expect(request.method == "ping")
        #expect(request.params == nil)
    }

    @Test func requestDecodingStringID() throws {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"tools/list\",\"params\":{}}"
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.id == .string("abc"))
        #expect(request.params == .object([:]))
    }

    @Test func requestWithoutIDIsNotification() throws {
        let json = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.id == nil)
    }

    @Test func errorEnvelopeUsesNullIDWhenAbsent() throws {
        let data = JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.parseError, message: "Parse error"))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded["id"] == .null)
        #expect(decoded["error"]?["code"]?.asInt == -32700)
    }

    @Test func toolResultShape() throws {
        let result = MCPToolResult.failure("nope").asJSONValue
        #expect(result["isError"]?.asBool == true)
        let content = result["content"]?.asArray
        #expect(content?.count == 1)
        #expect(content?.first?["type"]?.asString == "text")
        #expect(content?.first?["text"]?.asString == "nope")
    }
}
