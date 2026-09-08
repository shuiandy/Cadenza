import Foundation
import Network
import Security
import os

/// Loopback-only MCP server (Streamable HTTP, POST-only subset).
/// Owned by `AppState`; started/stopped from Settings. Binds strictly to the
/// loopback interface — never 0.0.0.0 (same discipline as OAuthCallbackServer).
actor MCPServer {
    enum Status: Equatable, Sendable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    enum Constants {
        static let defaultPort: UInt16 = 8585
        static let path = "/mcp"
        static let maxHeaderBytes = 16_384
        static let maxBodyBytes = 1_048_576
        /// Bounds sockets and watchdog tasks retained before authentication.
        static let maxConcurrentConnections = 32
        static let idleTimeout: Duration = .seconds(30)
        static var keychainTokenKey: String { MCPProfileCredentialKeys.activeLegacyTokenKey }
        static let enabledDefaultsKey = "mcpServerEnabled"
        static let writesEnabledDefaultsKey = "mcpWritesEnabled"
        static let externalImportEnabledDefaultsKey = "mcpExternalImportEnabled"
        static let portDefaultsKey = "mcpServerPort"
        static let meetingContextEnabledDefaultsKey = "mcpMeetingContextEnabled"
    }

    private static let log = Logger(subsystem: "com.shuiandy.Cadenza", category: "mcp")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: MCPHTTPConnection] = [:]
    /// Run tasks per connection so a transition can await in-flight
    /// router handlers instead of merely cancelling sockets.
    private var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var onStatus: (@Sendable (Status) -> Void)?
    private(set) var status: Status = .stopped

    // MARK: - Lifecycle

    /// Start (or restart) the listener. `port: 0` binds an ephemeral port —
    /// used by tests; production passes a fixed port with NO fallback, so a
    /// busy port fails loudly instead of silently breaking client configs.
    func start(port: UInt16, token: String, router: MCPRouter,
               accessStore: MCPClientAccessStore = .shared,
               onStatus: @escaping @Sendable (Status) -> Void) {
        stopInternal()
        self.onStatus = onStatus

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback  // never reachable off-box
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            if port == 0 {
                listener = try NWListener(using: parameters)
            } else {
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    Self.log.notice("MCP server rejected invalid port \(port, privacy: .public)")
                    setStatus(.failed(Self.listenerFailureMessage()))
                    return
                }
                listener = try NWListener(using: parameters, on: nwPort)
            }
        } catch {
            Self.log.notice(
                "MCP listener creation failed: \(error.localizedDescription, privacy: .private)"
            )
            setStatus(.failed(Self.listenerFailureMessage()))
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actualPort = listener.port?.rawValue ?? port
                Task { await self.handleListenerReady(
                    port: actualPort,
                    token: token,
                    router: router,
                    accessStore: accessStore
                ) }
            case .failed(let error):
                Task { await self.handleListenerFailed(error.localizedDescription) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.adopt(connection) }
        }
        listener.start(queue: DispatchQueue(label: "com.shuiandy.Cadenza.mcp-listener"))
    }

    func stop() {
        stopInternal()
        setStatus(.stopped)
    }

    /// Stops the listener and awaits every in-flight connection handler,
    /// bounded by the timeout. True means the server provably drained —
    /// no router handler can still touch the store; false means the
    /// caller must refuse the transition it was preparing.
    func stopAndWait(timeout: Duration = .seconds(3)) async -> Bool {
        let tasks = Array(connectionTasks.values)
        stopInternal()
        connectionTasks.removeAll()
        setStatus(.stopped)
        return await TaskDrain.awaitAll(tasks, timeout: timeout)
    }

    private func stopInternal() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let open = connections.values
        connections.removeAll()
        for connection in open {
            Task { await connection.shutdown() }
        }
        activeConfig = nil
    }

    // MARK: - Listener events

    /// Frozen at .ready time; new connections reuse it.
    private var activeConfig: (config: MCPHTTPConnection.Config, router: MCPRouter)?

    private func handleListenerReady(
        port: UInt16,
        token: String,
        router: MCPRouter,
        accessStore: MCPClientAccessStore
    ) {
        let config = MCPHTTPConnection.Config(
            authenticate: { presentedToken in
                accessStore.authenticate(presentedToken: presentedToken, legacyToken: token)
            },
            expectedPort: port,
            path: Constants.path,
            maxHeaderBytes: Constants.maxHeaderBytes,
            maxBodyBytes: Constants.maxBodyBytes,
            idleTimeout: Constants.idleTimeout
        )
        activeConfig = (config, router)
        setStatus(.running(port: port))
        Self.log.notice("MCP server listening on 127.0.0.1:\(port, privacy: .public)")
    }

    private func handleListenerFailed(_ message: String) {
        stopInternal()
        setStatus(.failed(Self.listenerFailureMessage()))
        Self.log.notice("MCP server failed: \(message, privacy: .private)")
    }

    private func adopt(_ connection: NWConnection) {
        guard let active = activeConfig else {
            connection.cancel()
            return
        }
        // An idle peer otherwise consumes a connection task for the full
        // watchdog interval without ever reaching authentication.
        guard connections.count < Constants.maxConcurrentConnections else {
            connection.cancel()
            return
        }
        let router = active.router
        let wrapped = MCPHTTPConnection(
            connection: connection,
            config: active.config,
            handler: { data, context in await router.handle(data, context: context) },
            onClosed: { [weak self] id in
                Task { await self?.forget(id) }
            }
        )
        let id = ObjectIdentifier(connection)
        connections[id] = wrapped
        connectionTasks[id] = Task { await wrapped.run() }
    }

    var activeConnectionCount: Int {
        connections.count
    }

    private func forget(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
    }

    private func setStatus(_ new: Status) {
        status = new
        onStatus?(new)
    }

    static func listenerFailureMessage(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "MCP server couldn't start. Check whether the selected port is available, then try again.",
            locale: locale
        )
    }

    // MARK: - Scopes

    /// Scope set matching the current permission toggles. Single source for
    /// newly connected clients (Settings) and the auto-provisioned CLI
    /// credential, so the two can never drift apart.
    static func scopesForNewConnection(defaults: UserDefaults = .standard) -> Set<MCPPermissionScope> {
        var scopes: Set<MCPPermissionScope> = [.recordingRead]
        let writes = defaults.bool(forKey: Constants.writesEnabledDefaultsKey)
        if writes {
            scopes.insert(.recordingWrite)
            scopes.insert(.exportWrite)
        }
        if defaults.bool(forKey: Constants.meetingContextEnabledDefaultsKey) {
            scopes.insert(.calendarContextRead)
            if writes { scopes.insert(.prepWrite) }
        }
        if defaults.bool(forKey: Constants.externalImportEnabledDefaultsKey) {
            scopes.insert(.externalImportWrite)
        }
        return scopes
    }

    // MARK: - Token management

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed: \(result)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Existing Keychain token, or a freshly generated + persisted one.
    static func loadOrCreateToken() -> String {
        if let existing = KeychainManager.shared.get(Constants.keychainTokenKey), !existing.isEmpty {
            return existing
        }
        let fresh = generateToken()
        KeychainManager.shared.setQuietly(fresh, forKey: Constants.keychainTokenKey)
        return fresh
    }

    /// Invalidate the shared legacy token and mint a new one. Per-client
    /// credentials remain valid.
    static func regenerateToken() -> String {
        let fresh = generateToken()
        KeychainManager.shared.setQuietly(fresh, forKey: Constants.keychainTokenKey)
        return fresh
    }
}
