import Foundation

// MARK: - Request identity and scopes

enum MCPPermissionScope: String, Codable, CaseIterable, Hashable, Sendable {
    case recordingRead = "recording.read"
    case recordingWrite = "recording.write"
    case calendarContextRead = "calendarContext.read"
    case prepWrite = "prep.write"
    case externalImportWrite = "externalImport.write"
    case exportWrite = "export.write"
}

struct MCPRequestContext: Equatable, Sendable {
    let clientID: String
    let clientName: String
    let scopes: Set<MCPPermissionScope>
    let isLegacy: Bool

    static let legacy = MCPRequestContext(
        clientID: "legacy",
        clientName: "Legacy global token",
        scopes: Set(MCPPermissionScope.allCases),
        isLegacy: true
    )

    func allows(_ scope: MCPPermissionScope) -> Bool {
        scopes.contains(scope)
    }
}

// MARK: - JSONValue

/// Minimal JSON tree used by the MCP layer for JSON-RPC envelopes, tool
/// schemas, and tool arguments. Avoids Any-based JSONSerialization so the
/// whole layer stays Sendable under Swift 6 strict concurrency.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    var asString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var asDouble: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Integer view of a JSON number; nil when the value has a fraction.
    var asInt: Int? {
        guard case .number(let value) = self,
              value.truncatingRemainder(dividingBy: 1) == 0,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    var asBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var asArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var asObject: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        asObject?[key]
    }
}

// MARK: Literal conveniences (readable schema/response building)

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    init(nilLiteral: ()) { self = .null }
}

// MARK: - Tool definitions

/// MCP client hints describing a tool's side effects. These are advisory to
/// clients, so Cadenza still enforces every permission at call time.
struct MCPToolAnnotations: Equatable, Sendable {
    let readOnlyHint: Bool
    let destructiveHint: Bool
    let idempotentHint: Bool
    let openWorldHint: Bool

    static let readOnly = MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    static func write(destructive: Bool = false, idempotent: Bool) -> MCPToolAnnotations {
        MCPToolAnnotations(
            readOnlyHint: false,
            destructiveHint: destructive,
            idempotentHint: idempotent,
            openWorldHint: false
        )
    }

    var asJSONValue: JSONValue {
        .object([
            "readOnlyHint": .bool(readOnlyHint),
            "destructiveHint": .bool(destructiveHint),
            "idempotentHint": .bool(idempotentHint),
            "openWorldHint": .bool(openWorldHint),
        ])
    }
}

/// Strongly typed representation of a tools/list entry. Input schemas remain
/// JSONValue because JSON Schema is itself an open-ended JSON vocabulary.
struct MCPToolDefinition: Equatable, Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let annotations: MCPToolAnnotations

    var asJSONValue: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": annotations.asJSONValue,
        ])
    }
}

// MARK: - JSON-RPC envelope

struct JSONRPCRequest: Decodable, Sendable {
    let jsonrpc: String?
    /// Absent (or explicit null) id ⇒ notification: never gets a response.
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

enum JSONRPC {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602

    static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: JSONValue?, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": "2.0",
            "id": id ?? .null,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
    }

    /// Deterministic encoding (sorted keys) so tests can assert on substrings.
    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSONValue.encode(to:) never throws for the cases we construct.
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}

// MARK: - Tool result

/// Result of a tools/call. Tool-level failures travel as `isError: true`
/// inside a successful JSON-RPC response (per MCP spec) — they must not
/// surface as protocol-level errors.
struct MCPToolResult: Sendable {
    let text: String
    let isError: Bool

    static func ok(_ text: String) -> MCPToolResult { .init(text: text, isError: false) }
    static func failure(_ message: String) -> MCPToolResult { .init(text: message, isError: true) }

    var asJSONValue: JSONValue {
        .object([
            "content": .array([.object(["type": "text", "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }
}
