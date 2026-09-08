import Foundation
import Testing
@testable import Cadenza

@Suite("MCPBridgeCLI")
struct MCPBridgeCLITests {

    // MARK: - Parsing

    @Test func noArgumentsRunsTheBridge() {
        #expect(MCPBridgeCLI.parse([]) == .bridge(clientID: "stdio"))
        #expect(MCPBridgeCLI.parse(["--client", "claude-desktop"]) == .bridge(clientID: "claude-desktop"))
        #expect(MCPBridgeCLI.parse(["serve"]) == .bridge(clientID: "stdio"))
        #expect(MCPBridgeCLI.parse(["serve", "--client", "codex-cli"]) == .bridge(clientID: "codex-cli"))
    }

    @Test func subcommandsDefaultToTheCLIClientIdentity() {
        #expect(MCPBridgeCLI.parse(["list"])
            == .toolCall(name: "list_recordings", arguments: nil, json: false, clientID: "cadenza-cli"))
        #expect(MCPBridgeCLI.parse(["tools"]) == .toolsList(json: false, clientID: "cadenza-cli"))
        #expect(MCPBridgeCLI.parse(["tags", "--json"])
            == .toolCall(name: "list_tags", arguments: nil, json: true, clientID: "cadenza-cli"))
        #expect(MCPBridgeCLI.parse(["list", "--client", "special"])
            == .toolCall(name: "list_recordings", arguments: nil, json: false, clientID: "special"))
    }

    @Test func searchJoinsTheQueryWords() {
        #expect(MCPBridgeCLI.parse(["search", "quarterly", "planning"])
            == .toolCall(name: "search_transcripts",
                         arguments: .object(["query": .string("quarterly planning")]),
                         json: false, clientID: "cadenza-cli"))
        if case .invalid = MCPBridgeCLI.parse(["search"]) {} else {
            Issue.record("search without a query must be invalid")
        }
    }

    @Test func transcriptAndSummaryCarryTheRecordingID() {
        #expect(MCPBridgeCLI.parse(["transcript", "ABC-123"])
            == .toolCall(name: "get_transcript",
                         arguments: .object(["recordingId": .string("ABC-123")]),
                         json: false, clientID: "cadenza-cli"))
        #expect(MCPBridgeCLI.parse(["transcript", "ABC-123", "--segments"])
            == .toolCall(name: "get_transcript",
                         arguments: .object(["recordingId": .string("ABC-123"),
                                             "format": .string("segments")]),
                         json: false, clientID: "cadenza-cli"))
        #expect(MCPBridgeCLI.parse(["summary", "ABC-123"])
            == .toolCall(name: "get_summary",
                         arguments: .object(["recordingId": .string("ABC-123")]),
                         json: false, clientID: "cadenza-cli"))
        if case .invalid = MCPBridgeCLI.parse(["transcript"]) {} else {
            Issue.record("transcript without an id must be invalid")
        }
    }

    @Test func actionsRecordingIDIsOptional() {
        #expect(MCPBridgeCLI.parse(["actions"])
            == .toolCall(name: "list_action_items", arguments: nil, json: false, clientID: "cadenza-cli"))
        #expect(MCPBridgeCLI.parse(["actions", "ID-1"])
            == .toolCall(name: "list_action_items",
                         arguments: .object(["recordingId": .string("ID-1")]),
                         json: false, clientID: "cadenza-cli"))
    }

    @Test func genericCallParsesJSONObjectArguments() {
        #expect(MCPBridgeCLI.parse(["call", "list_recordings"])
            == .toolCall(name: "list_recordings", arguments: nil, json: false, clientID: "cadenza-cli"))
        #expect(MCPBridgeCLI.parse(["call", "search_transcripts", #"{"query": "q", "limit": 3}"#])
            == .toolCall(name: "search_transcripts",
                         arguments: .object(["query": .string("q"), "limit": .number(3)]),
                         json: false, clientID: "cadenza-cli"))
        for bad in [["call"], ["call", "t", "not json"], ["call", "t", "[1,2]"], ["call", "t", "\"str\""]] {
            if case .invalid = MCPBridgeCLI.parse(bad) {} else {
                Issue.record("should be invalid: \(bad)")
            }
        }
    }

    @Test func helpAndUnknownCommands() {
        #expect(MCPBridgeCLI.parse(["help"]) == .help)
        #expect(MCPBridgeCLI.parse(["--help"]) == .help)
        #expect(MCPBridgeCLI.parse(["-h"]) == .help)
        if case .invalid = MCPBridgeCLI.parse(["frobnicate"]) {} else {
            Issue.record("unknown command must be invalid")
        }
    }

    // MARK: - Request building

    @Test func toolCallMessageIsSingleLineJSONRPC() throws {
        let data = MCPBridgeCLI.toolCallMessage(
            name: "get_summary",
            arguments: .object(["recordingId": .string("X")])
        )
        #expect(!data.contains(UInt8(ascii: "\n")))  // stdio framing safety
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["method"] as? String == "tools/call")
        #expect(root["jsonrpc"] as? String == "2.0")
        let params = root["params"] as? [String: Any]
        #expect(params?["name"] as? String == "get_summary")
        #expect((params?["arguments"] as? [String: Any])?["recordingId"] as? String == "X")

        let list = try #require(JSONSerialization.jsonObject(with: MCPBridgeCLI.toolsListMessage()) as? [String: Any])
        #expect(list["method"] as? String == "tools/list")
    }

    // MARK: - Response rendering

    @Test func toolOutcomeExtractsTextAndErrorFlag() {
        let ok = Data(#"{"id":1,"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"hello"}],"isError":false}}"#.utf8)
        let outcome = MCPBridgeCLI.toolOutcome(fromResponse: ok)
        #expect(outcome?.text == "hello")
        #expect(outcome?.isError == false)

        let toolError = Data(#"{"id":1,"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"nope"}],"isError":true}}"#.utf8)
        #expect(MCPBridgeCLI.toolOutcome(fromResponse: toolError)?.isError == true)

        let rpcError = Data(#"{"id":1,"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        #expect(MCPBridgeCLI.toolOutcome(fromResponse: rpcError) == nil)
        #expect(MCPBridgeCLI.errorMessage(fromResponse: rpcError) == "Method not found")
        #expect(MCPBridgeCLI.errorMessage(fromResponse: ok) == nil)
    }

    @Test func toolsSummaryAlignsNamesAndTakesFirstDescriptionLine() {
        let response = Data("""
        {"id":1,"jsonrpc":"2.0","result":{"tools":[
          {"name":"list_recordings","description":"List recordings.\\nSecond line."},
          {"name":"tag","description":"Short."}
        ]}}
        """.utf8)
        let summary = MCPBridgeCLI.toolsSummary(fromResponse: response)
        let lines = summary?.components(separatedBy: "\n")
        #expect(lines?.count == 2)
        #expect(lines?[0].hasPrefix("list_recordings  ") == true)
        #expect(lines?[0].contains("Second line") == false)
        #expect(lines?[1].hasPrefix("tag") == true)
    }

    // MARK: - Provisioning contract

    @Test func cliClientIdentityIsAValidCredentialFileName() {
        #expect(MCPBridgeRuntime.isValidClientID(MCPBridgeCLI.cliClientID))
        // Distinct from every Settings-managed client so its records never
        // collide with a connector row.
        #expect(!MCPClientConnector.Client.allCases.map(\.accessID).contains(MCPBridgeCLI.cliClientID))
    }

    @Test func scopesForNewConnectionTrackTheToggles() throws {
        let defaults = try #require(UserDefaults(suiteName: "cli-scopes-\(UUID().uuidString)"))
        #expect(MCPServer.scopesForNewConnection(defaults: defaults) == [.recordingRead])

        defaults.set(true, forKey: MCPServer.Constants.writesEnabledDefaultsKey)
        #expect(MCPServer.scopesForNewConnection(defaults: defaults)
            == [.recordingRead, .recordingWrite, .exportWrite])

        defaults.set(true, forKey: MCPServer.Constants.meetingContextEnabledDefaultsKey)
        defaults.set(true, forKey: MCPServer.Constants.externalImportEnabledDefaultsKey)
        #expect(MCPServer.scopesForNewConnection(defaults: defaults)
            == [.recordingRead, .recordingWrite, .exportWrite,
                .calendarContextRead, .prepWrite, .externalImportWrite])
    }
}
