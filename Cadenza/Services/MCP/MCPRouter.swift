import Foundation

// MARK: - Tool provider abstraction

/// Surface the router needs from the tool layer. Implemented by
/// `MCPToolRegistry`; stubbed in router tests.
protocol MCPToolProviding: Sendable {
    /// Tool definitions for tools/list — already filtered by the write switch.
    func toolDefinitions(context: MCPRequestContext) async -> [JSONValue]
    /// Execute a tool. Unknown tool or handler failure ⇒ `isError: true` result.
    func call(name: String, arguments: JSONValue?, context: MCPRequestContext) async -> MCPToolResult
}

extension MCPToolProviding {
    func toolDefinitions() async -> [JSONValue] {
        await toolDefinitions(context: .legacy)
    }

    func call(name: String, arguments: JSONValue?) async -> MCPToolResult {
        await call(name: name, arguments: arguments, context: .legacy)
    }
}

// MARK: - Router

/// JSON-RPC 2.0 dispatch for the MCP protocol subset (spec §4 whitelist):
/// initialize / notifications/initialized / ping / tools/list / tools/call.
/// Everything else → -32601. Batches → -32600. Stateless: no session ids.
struct MCPRouter: Sendable {
    let tools: any MCPToolProviding
    let serverVersion: String

    static let serverName = "Cadenza"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26"]
    static let latestProtocolVersion = supportedProtocolVersions[0]
    static let instructions =
        "Cadenza exposes meeting transcripts and summaries. "
        + "Start with search_transcripts or list_recordings to find a recording id, "
        + "then use get_transcript / get_summary. Long transcripts are paginated via nextCursor."

    /// Handle one JSON-RPC message. Returns response bytes, or nil for
    /// notifications (which must never be answered).
    func handle(_ data: Data, context: MCPRequestContext = .legacy) async -> Data? {
        if isBatch(data) {
            return JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.invalidRequest,
                                                message: "Batch requests are not supported"))
        }
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else {
            return JSONRPC.encode(JSONRPC.error(id: nil, code: JSONRPC.parseError, message: "Parse error"))
        }

        let isNotification = request.id == nil || request.id == .null
        if isNotification {
            // notifications/initialized and any other notification: accept silently.
            return nil
        }
        let id = request.id ?? .null

        switch request.method {
        case "initialize":
            return JSONRPC.encode(JSONRPC.response(id: id, result: initializeResult(params: request.params)))
        case "ping":
            return JSONRPC.encode(JSONRPC.response(id: id, result: .object([:])))
        case "tools/list":
            let definitions = await tools.toolDefinitions(context: context)
            return JSONRPC.encode(JSONRPC.response(id: id, result: .object(["tools": .array(definitions)])))
        case "tools/call":
            guard let name = request.params?["name"]?.asString else {
                return JSONRPC.encode(JSONRPC.error(id: id, code: JSONRPC.invalidParams,
                                                    message: "tools/call requires a string 'name' parameter"))
            }
            let result = await tools.call(name: name, arguments: request.params?["arguments"], context: context)
            return JSONRPC.encode(JSONRPC.response(id: id, result: result.asJSONValue))
        default:
            return JSONRPC.encode(JSONRPC.error(id: id, code: JSONRPC.methodNotFound,
                                                message: "Method not found: \(request.method)"))
        }
    }

    private func initializeResult(params: JSONValue?) -> JSONValue {
        let requestedVersion = params?["protocolVersion"]?.asString
        let version = requestedVersion.flatMap { requested in
            Self.supportedProtocolVersions.contains(requested) ? requested : nil
        } ?? Self.latestProtocolVersion
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(serverVersion),
            ]),
            "instructions": .string(Self.instructions),
        ])
    }

    private func isBatch(_ data: Data) -> Bool {
        for byte in data {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue  // whitespace
            case UInt8(ascii: "["): return true
            default: return false
            }
        }
        return false
    }
}
