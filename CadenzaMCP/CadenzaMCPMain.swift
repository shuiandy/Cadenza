import AppKit
import Foundation

/// `cadenza-mcp` — stdio MCP bridge to the Cadenza app's loopback HTTP server.
///
/// Every MCP client speaks the stdio transport and configures it the same
/// way (a command plus args), so this binary is the one config shape all
/// clients share. It owns the messy parts a config file can't:
/// - endpoint discovery via `endpoint.json` (port changes never break configs),
/// - per-client credentials from the app's 0600 token files (no secrets in
///   any client's config),
/// - launching the app in the background and waiting for the listener when
///   a client starts before Cadenza does (the Claude Desktop login race).
///
/// Protocol: newline-delimited JSON-RPC on stdin/stdout (MCP stdio framing);
/// each message is POSTed to the server, whose responses are compact
/// single-line JSON. The server never pushes messages, so stdout only ever
/// carries direct responses. Notifications get HTTP 202 and no output.
@main
struct CadenzaMCPBridge {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)  // a vanished client must not kill us mid-write

        let environment = ProcessInfo.processInfo.environment
        switch MCPBridgeCLI.parse(Array(CommandLine.arguments.dropFirst())) {
        case .help:
            print(MCPBridgeCLI.helpText)

        case .invalid(let message):
            FileHandle.standardError.write(Data("cadenza-mcp: \(message)\n".utf8))
            exit(2)

        case .bridge(let clientID):
            await runBridge(clientID: clientID, environment: environment)

        case .toolsList(let json, let clientID):
            let status = await runSingleRequest(
                MCPBridgeCLI.toolsListMessage(),
                clientID: clientID,
                environment: environment,
                json: json,
                render: MCPBridgeCLI.toolsSummary(fromResponse:)
            )
            exit(status)

        case .toolCall(let name, let arguments, let json, let clientID):
            let status = await runSingleRequest(
                MCPBridgeCLI.toolCallMessage(name: name, arguments: arguments),
                clientID: clientID,
                environment: environment,
                json: json,
                render: nil
            )
            exit(status)
        }
    }

    private static func runBridge(clientID: String, environment: [String: String]) async {
        let session = BridgeSession(clientID: clientID, environment: environment)
        session.log("starting for client '\(clientID)'")
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                await session.handle(Data(trimmed.utf8))
            }
        } catch {
            session.log("stdin closed with error: \(error.localizedDescription)")
        }
        session.log("stdin closed — exiting")
    }

    /// Executes one subcommand request end to end and returns the process
    /// exit status. `render` formats a successful response for humans
    /// (tools listing); nil means "print the tool result's text content".
    private static func runSingleRequest(
        _ message: Data,
        clientID: String,
        environment: [String: String],
        json: Bool,
        render: ((Data) -> String?)?
    ) async -> Int32 {
        let session = BridgeSession(clientID: clientID, environment: environment,
                                    waitsForCredentialOnLaunch: true)
        switch await session.deliver(message) {
        case .accepted:
            return 0  // unreachable: subcommand requests always carry an id

        case .failure(let description):
            FileHandle.standardError.write(Data("cadenza-mcp: \(description)\n".utf8))
            return 1

        case .response(let data):
            if json {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                if MCPBridgeCLI.errorMessage(fromResponse: data) != nil { return 1 }
                return MCPBridgeCLI.toolOutcome(fromResponse: data)?.isError == true ? 1 : 0
            }
            if let errorMessage = MCPBridgeCLI.errorMessage(fromResponse: data) {
                FileHandle.standardError.write(Data("cadenza-mcp: \(errorMessage)\n".utf8))
                return 1
            }
            if let render {
                guard let rendered = render(data) else {
                    FileHandle.standardError.write(Data("cadenza-mcp: unexpected response shape\n".utf8))
                    return 1
                }
                print(rendered)
                return 0
            }
            guard let outcome = MCPBridgeCLI.toolOutcome(fromResponse: data) else {
                FileHandle.standardError.write(Data("cadenza-mcp: unexpected response shape\n".utf8))
                return 1
            }
            if outcome.isError {
                FileHandle.standardError.write(Data("cadenza-mcp: \(outcome.text)\n".utf8))
                return 1
            }
            print(outcome.text)
            return 0
        }
    }
}

/// Single-task session state. Messages are processed strictly sequentially,
/// which preserves JSON-RPC response ordering without any queueing.
final class BridgeSession {
    private let clientID: String
    private let environment: [String: String]
    private let runtime: MCPBridgeRuntime
    private let urlSession: URLSession
    private let stdout = FileHandle.standardOutput
    private let stderr = FileHandle.standardError

    /// Launching is attempted at most once per bridge process: if the app
    /// came up and went away again, something is wrong enough that spamming
    /// launch events would only make it worse.
    private var launchAttempted = false
    /// After a warm probe fails (app running, MCP disabled in Settings) requests
    /// fail fast until this instant instead of each polling for 10 s. Cleared
    /// the moment a probe succeeds, so re-enabling MCP recovers on its own.
    private var unavailableUntil: ContinuousClock.Instant?
    private static let unavailableGrace: Duration = .seconds(30)

    /// CLI subcommands set this: a missing credential is expected before the
    /// app's first run (the app provisions `cadenza-cli` when its server
    /// starts), so launch and wait once before giving up on it.
    private let waitsForCredentialOnLaunch: Bool

    private static let appBundleID = "com.shuiandy.Cadenza"
    private static let coldStartTimeout: Duration = .seconds(45)
    private static let warmProbeTimeout: Duration = .seconds(10)
    private static let probeInterval: Duration = .milliseconds(250)

    init(clientID: String, environment: [String: String],
         waitsForCredentialOnLaunch: Bool = false) {
        self.clientID = clientID
        self.environment = environment
        self.waitsForCredentialOnLaunch = waitsForCredentialOnLaunch
        if let override = environment["CADENZA_MCP_SUPPORT_DIR"], !override.isEmpty {
            runtime = MCPBridgeRuntime(root: URL(fileURLWithPath: override, isDirectory: true))
        } else {
            runtime = MCPBridgeRuntime.standard()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300  // tool calls can be slow
        urlSession = URLSession(configuration: configuration)
    }

    func log(_ message: String) {
        stderr.write(Data("[cadenza-mcp] \(message)\n".utf8))
    }

    // MARK: - Message pump

    func handle(_ message: Data) async {
        // The id is only needed to synthesize bridge-level errors; the raw
        // bytes are forwarded untouched so the server does the real parsing
        // (including answering malformed requests itself when reachable).
        let requestID = (try? JSONDecoder().decode(JSONRPCRequest.self, from: message))?.id

        switch await deliver(message) {
        case .response(let body):
            writeMessage(body)
        case .accepted:
            break  // notification — must never be answered
        case .failure(let description):
            log(description)
            if let requestID, requestID != .null {
                writeMessage(JSONRPC.encode(JSONRPC.error(id: requestID, code: -32000,
                                                          message: description)))
            }
        }
    }

    private func writeMessage(_ body: Data) {
        var framed = body
        framed.append(UInt8(ascii: "\n"))
        stdout.write(framed)
    }

    // MARK: - Delivery

    enum DeliveryOutcome {
        case response(Data)
        case accepted
        case failure(String)
    }

    private enum PostOutcome {
        case http(status: Int, body: Data)
        case unreachable
        case transport(String)
    }

    func deliver(_ message: Data) async -> DeliveryOutcome {
        var resolvedToken = currentToken()
        if resolvedToken == nil, waitsForCredentialOnLaunch {
            // First CLI use on a fresh machine: bring the app up — its server
            // start provisions the CLI credential — then look again.
            _ = await waitForServer()
            resolvedToken = currentToken()
        }
        guard let token = resolvedToken else {
            if waitsForCredentialOnLaunch {
                return .failure(
                    "No CLI credential yet. Launch Cadenza once and enable the MCP server "
                    + "in Settings → Integrations; the credential is provisioned automatically."
                )
            }
            return .failure(
                "No Cadenza credential found for client '\(clientID)'. "
                + "Open Cadenza → Settings → Integrations and connect this client."
            )
        }

        var outcome = await post(message, token: token)
        if case .unreachable = outcome {
            if let unavailableUntil, ContinuousClock.now < unavailableUntil {
                // Inside the grace window: the app is running with MCP off.
            } else if await waitForServer() {
                unavailableUntil = nil
                outcome = await post(message, token: currentToken() ?? token)
            } else if isAppRunning() {
                unavailableUntil = ContinuousClock.now.advanced(by: Self.unavailableGrace)
            }
        }
        if case .http(401, _) = outcome {
            // The token may have rotated on disk while this bridge was alive
            // (a reconnect in Settings). Pick up the fresh one once.
            if let fresh = currentToken(), fresh != token {
                outcome = await post(message, token: fresh)
            }
        }

        switch outcome {
        case .http(200, let body):
            return .response(body)
        case .http(202, _):
            return .accepted
        case .http(401, _):
            return .failure(
                "Cadenza rejected this client's credential. "
                + "Reconnect '\(clientID)' in Cadenza → Settings → Integrations."
            )
        case .http(let status, let body):
            let detail = String(data: body, encoding: .utf8) ?? ""
            return .failure("Cadenza's MCP server answered HTTP \(status). \(detail)")
        case .unreachable:
            return .failure(
                "Cadenza's MCP server is not reachable. "
                + "Open Cadenza and enable the MCP server in Settings → Integrations."
            )
        case .transport(let description):
            return .failure(description)
        }
    }

    private func post(_ body: Data, token: String) async -> PostOutcome {
        var request = URLRequest(url: currentEndpoint())
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transport("Unexpected non-HTTP response from Cadenza's MCP server.")
            }
            return .http(status: http.statusCode, body: data)
        } catch let error as URLError where Self.indicatesServerDown(error) {
            return .unreachable
        } catch {
            return .transport("Could not reach Cadenza's MCP server: \(error.localizedDescription)")
        }
    }

    private static func indicatesServerDown(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    // MARK: - Discovery

    /// Re-resolved on every request: the app rewrites `endpoint.json` when
    /// its listener comes up, so a bridge started before a port change
    /// converges without restarting.
    private func currentEndpoint() -> URL {
        if let override = environment["CADENZA_MCP_ENDPOINT"], let url = URL(string: override) {
            return url
        }
        let stored = runtime.readEndpointURL() ?? MCPBridgeRuntime.fallbackServerURL
        return URL(string: stored) ?? URL(string: MCPBridgeRuntime.fallbackServerURL)!
    }

    private func currentToken() -> String? {
        if let override = environment["CADENZA_MCP_TOKEN"], !override.isEmpty {
            return override
        }
        return runtime.credential(for: clientID)
    }

    // MARK: - App launch & wait

    /// True once the server answers HTTP on the current endpoint.
    private func waitForServer() async -> Bool {
        let deadline: Duration
        if isAppRunning() {
            // Running but not listening: either still booting or MCP is
            // disabled in Settings. Give a warm boot a short grace period.
            deadline = Self.warmProbeTimeout
        } else if environment["CADENZA_MCP_NO_LAUNCH"] == "1" || launchAttempted {
            return await probe()
        } else {
            launchAttempted = true
            guard await launchApp() else { return false }
            deadline = Self.coldStartTimeout
        }

        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while clock.now < end {
            if await probe() { return true }
            try? await Task.sleep(for: Self.probeInterval)
        }
        return false
    }

    /// Only ever `open`s the app when it is NOT already running: opening a
    /// running app delivers a reopen event that activates the main window —
    /// the "Cadenza pops up whenever a client starts" bug.
    private func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.appBundleID).isEmpty
    }

    private func launchApp() async -> Bool {
        guard let appURL = locateApp() else {
            log("could not locate Cadenza.app to launch")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            log("launched \(appURL.path), waiting for the MCP listener")
            return true
        } catch {
            log("failed to launch \(appURL.path): \(error.localizedDescription)")
            return false
        }
    }

    /// The bridge ships inside the app bundle, so its own location names the
    /// app: …/Cadenza.app/Contents/MacOS/cadenza-mcp. A bare products
    /// directory (dev builds) falls back to a sibling Cadenza.app, then to
    /// Launch Services.
    private func locateApp() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        let sibling = bundleURL.appendingPathComponent("Cadenza.app")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleID)
    }

    /// Any HTTP response proves the listener is up — a GET earns a 405, and
    /// that is enough.
    private func probe() async -> Bool {
        var request = URLRequest(url: currentEndpoint())
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        guard let (_, response) = try? await urlSession.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}
