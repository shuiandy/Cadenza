import Foundation

/// Command surface of the `cadenza-mcp` binary beyond the default MCP stdio
/// bridge: human- and agent-facing subcommands that call the same MCP tools
/// over the same delivery path (endpoint discovery, credential files,
/// launch-if-needed). Pure parsing and formatting only — compiled into both
/// the CLI target and the app, so the app's test bundle covers it.
enum MCPBridgeCLI {
    /// Client identity for subcommands. The app provisions this credential
    /// automatically whenever its MCP server starts, so `cadenza-mcp list`
    /// works without a Connect step; usage still shows per-client in the
    /// access records.
    static let cliClientID = "cadenza-cli"
    /// Identity used when the bridge is launched without `--client` (a
    /// hand-written config).
    static let defaultBridgeClientID = "stdio"

    enum Invocation: Equatable {
        /// Run as the MCP stdio bridge (default when no subcommand is given).
        case bridge(clientID: String)
        case toolsList(json: Bool, clientID: String)
        case toolCall(name: String, arguments: JSONValue?, json: Bool, clientID: String)
        case help
        case invalid(String)
    }

    // MARK: - Parsing

    static func parse(_ arguments: [String]) -> Invocation {
        var positional: [String] = []
        var clientID: String?
        var json = false
        var segments = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--client":
                guard index + 1 < arguments.count else { return .invalid("--client requires a value") }
                clientID = arguments[index + 1]
                index += 2
            case "--json":
                json = true
                index += 1
            case "--segments":
                segments = true
                index += 1
            case "--help", "-h":
                return .help
            default:
                positional.append(argument)
                index += 1
            }
        }

        guard let command = positional.first else {
            return .bridge(clientID: clientID ?? defaultBridgeClientID)
        }
        let rest = Array(positional.dropFirst())
        let cli = clientID ?? cliClientID

        switch command {
        case "help":
            return .help
        case "serve":
            return .bridge(clientID: clientID ?? defaultBridgeClientID)
        case "tools":
            return .toolsList(json: json, clientID: cli)
        case "call":
            guard let name = rest.first, !name.isEmpty else {
                return .invalid("usage: cadenza-mcp call <tool> ['{\"key\": \"value\"}']")
            }
            var toolArguments: JSONValue?
            if rest.count >= 2 {
                let payload = rest.dropFirst().joined(separator: " ")
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
                      case .object = decoded else {
                    return .invalid("tool arguments must be a single JSON object, e.g. '{\"limit\": 5}'")
                }
                toolArguments = decoded
            }
            return .toolCall(name: name, arguments: toolArguments, json: json, clientID: cli)
        case "list":
            return .toolCall(name: "list_recordings", arguments: nil, json: json, clientID: cli)
        case "search":
            guard !rest.isEmpty else { return .invalid("usage: cadenza-mcp search <query>") }
            return .toolCall(
                name: "search_transcripts",
                arguments: .object(["query": .string(rest.joined(separator: " "))]),
                json: json,
                clientID: cli
            )
        case "transcript":
            guard let id = rest.first else {
                return .invalid("usage: cadenza-mcp transcript <recording-id> [--segments]")
            }
            var toolArguments: [String: JSONValue] = ["recordingId": .string(id)]
            if segments { toolArguments["format"] = .string("segments") }
            return .toolCall(name: "get_transcript", arguments: .object(toolArguments), json: json, clientID: cli)
        case "summary":
            guard let id = rest.first else { return .invalid("usage: cadenza-mcp summary <recording-id>") }
            return .toolCall(
                name: "get_summary",
                arguments: .object(["recordingId": .string(id)]),
                json: json,
                clientID: cli
            )
        case "tags":
            return .toolCall(name: "list_tags", arguments: nil, json: json, clientID: cli)
        case "actions":
            let toolArguments = rest.first.map { JSONValue.object(["recordingId": .string($0)]) }
            return .toolCall(name: "list_action_items", arguments: toolArguments, json: json, clientID: cli)
        default:
            return .invalid("unknown command '\(command)'. Run 'cadenza-mcp help' for usage.")
        }
    }

    static let helpText = """
    cadenza-mcp: Cadenza's MCP stdio bridge and command-line client.

    Without a subcommand it runs as an MCP stdio server (what client configs
    invoke). Subcommands call the same MCP tools directly; Cadenza is
    launched in the background when it is not already running.

    Usage:
      cadenza-mcp [--client <id>]              run the stdio bridge (default)
      cadenza-mcp list                         recent recordings
      cadenza-mcp search <query>               full-text search
      cadenza-mcp transcript <id> [--segments] transcript of one recording
      cadenza-mcp summary <id>                 summary of one recording
      cadenza-mcp tags                         tag vocabulary with counts
      cadenza-mcp actions [<id>]               action items
      cadenza-mcp tools                        list every available MCP tool
      cadenza-mcp call <tool> ['{JSON}']       call any tool directly
      cadenza-mcp help                         this text

    Options:
      --json        print the raw JSON-RPC response
      --client <id> authenticate as a specific client id
    """

    // MARK: - Request building

    static func toolCallMessage(name: String, arguments: JSONValue?) -> Data {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let arguments { params["arguments"] = arguments }
        return JSONRPC.encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("tools/call"),
            "params": .object(params),
        ]))
    }

    static func toolsListMessage() -> Data {
        JSONRPC.encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("tools/list"),
        ]))
    }

    // MARK: - Response rendering

    /// The `message` of a JSON-RPC error envelope, nil for success responses.
    static func errorMessage(fromResponse data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return (error["message"] as? String) ?? "unknown JSON-RPC error"
    }

    /// Concatenated text content of a tools/call result. nil when the
    /// response is not a tool result at all.
    static func toolOutcome(fromResponse data: Data) -> (text: String, isError: Bool)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }
        let isError = result["isError"] as? Bool ?? false
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, isError)
    }

    /// One line per tool: `name  description-first-line`.
    static func toolsSummary(fromResponse data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return nil }
        let width = tools.compactMap { ($0["name"] as? String)?.count }.max() ?? 0
        let lines = tools.compactMap { tool -> String? in
            guard let name = tool["name"] as? String else { return nil }
            let description = (tool["description"] as? String ?? "")
                .components(separatedBy: .newlines).first ?? ""
            let padded = name.padding(toLength: max(width, name.count), withPad: " ", startingAt: 0)
            return "\(padded)  \(String(description.prefix(120)))"
        }
        return lines.joined(separator: "\n")
    }
}
