import Foundation
import Network
import os
import Security

/// Sendable callback boundary around one exact realtime connection. Tests inject
/// a controlled transport; production wraps `NWConnection` without exposing it
/// to the session state machine.
struct GeminiRealtimeTransport: Sendable {
    typealias SendCompletion = @Sendable (Error?) -> Void
    typealias ReceiveCompletion = @Sendable (Data?, Error?) -> Void

    private let sendOperation: @Sendable (Data, @escaping SendCompletion) -> Void
    private let receiveOperation: @Sendable (Int, @escaping ReceiveCompletion) -> Void
    private let cancelOperation: @Sendable () -> Void
    private let cancellationGate = GeminiRealtimeCancellationGate()
    let id = UUID()

    init(
        send: @escaping @Sendable (Data, @escaping SendCompletion) -> Void,
        receive: @escaping @Sendable (Int, @escaping ReceiveCompletion) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.sendOperation = send
        self.receiveOperation = receive
        self.cancelOperation = cancel
    }

    init(connection: NWConnection) {
        self.init(
            send: { data, completion in
                connection.send(content: data, completion: .contentProcessed(completion))
            },
            receive: { maxLength, completion in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: maxLength
                ) { data, _, _, error in
                    completion(data, error)
                }
            },
            cancel: { connection.cancel() }
        )
    }

    func send(_ data: Data, completion: @escaping SendCompletion) {
        sendOperation(data, completion)
    }

    func receive(maxLength: Int, completion: @escaping ReceiveCompletion) {
        receiveOperation(maxLength, completion)
    }

    func cancel() {
        cancellationGate.cancelOnce(cancelOperation)
    }

    func matches(_ other: GeminiRealtimeTransport) -> Bool {
        id == other.id
    }
}

private final class GeminiRealtimeCancellationGate: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func cancelOnce(_ operation: @Sendable () -> Void) {
        let shouldCancel = lock.withLock { cancelled in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        if shouldCancel {
            operation()
        }
    }
}

/// Resume-once state for callback APIs. A terminal result is retained even when
/// cancellation wins before the continuation is installed, closing that race.
private final class GeminiRealtimePendingIO<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, Error>?
        var terminalResult: Result<Value, Error>?
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let terminalResult = lock.withLock { state -> Result<Value, Error>? in
            if let terminalResult = state.terminalResult {
                return terminalResult
            }
            state.continuation = continuation
            return nil
        }
        if let terminalResult {
            continuation.resume(with: terminalResult)
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { state in
            if state.terminalResult != nil {
                return true
            }
            state.timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let captured = lock.withLock { state -> (
            CheckedContinuation<Value, Error>?,
            Task<Void, Never>?
        )? in
            guard state.terminalResult == nil else { return nil }
            state.terminalResult = result
            let continuation = state.continuation
            let timeoutTask = state.timeoutTask
            state.continuation = nil
            state.timeoutTask = nil
            return (continuation, timeoutTask)
        }
        captured?.1?.cancel()
        captured?.0?.resume(with: result)
        return captured != nil
    }
}

/// Advance notice that the Live API is about to close a connection. Gemini
/// sends it about 50 s before its session-duration cutoff and aborts a client
/// that is still attached when `timeLeft` runs out (close code 1008).
struct GeminiRealtimeGoAway: Equatable, Sendable {
    private static let maximumTimeLeftSeconds: Double = 3_600

    /// nil when the server omitted the field or sent something unparseable.
    let timeLeft: Duration?

    init?(message: [String: Any]) {
        guard let body = (message["goAway"] ?? message["go_away"]) as? [String: Any] else {
            return nil
        }
        timeLeft = Self.duration(from: body["timeLeft"] ?? body["time_left"])
    }

    /// Protobuf `Duration` in its JSON form: decimal seconds with an `s`
    /// suffix, such as "50s" or "1.5s".
    private static func duration(from value: Any?) -> Duration? {
        guard let text = value as? String,
              text.hasSuffix("s"),
              let seconds = Double(text.dropLast()),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        return .seconds(min(seconds, maximumTimeLeftSeconds))
    }
}

/// Real-time transcription using Gemini Multimodal Live API over WebSocket.
/// Uses raw NWConnection (TCP + TLS) with manual WebSocket handshake & framing
/// to force HTTP/1.1 and control the request URI path.
///
/// Gemini caps a Live connection at about ten minutes and announces the cut
/// with `goAway`. The transcriber rotates to a fresh connection behind the
/// same transcript stream, so callers only ever see a failure when that
/// rotation cannot finish in time.
actor GeminiRealtimeTranscriber: TranscriptionService {
    /// Framing state for one socket. A goAway rotation keeps the retiring and
    /// the replacement socket reading at the same time, so a partial frame on
    /// one must never land in the other's buffer.
    private struct Framing {
        var receiveBuffer = Data()
        var fragmentedTextBuffer: Data?
    }

    /// A replacement being dialed after goAway. Audio keeps flowing to the
    /// retiring socket until the replacement has acknowledged setup.
    private struct PendingRotation {
        let retiring: GeminiRealtimeTransport
        var replacement: GeminiRealtimeTransport?
        var task: Task<Void, Never>?
        var deadlineTask: Task<Void, Never>?
    }

    /// The retiring socket once audio has moved to its replacement. It was
    /// sent audioStreamEnd, so text for its last audio may still be on the way.
    /// That text is delivered first and the replacement's is held back for the
    /// whole drain window: the manager keeps one open hypothesis, and
    /// interleaving the two sockets would overwrite or reorder it.
    ///
    /// The window always runs to the end (unless the server closes the socket
    /// first). A final arriving after the flush does not mean the flush was
    /// answered: it can be the previous sentence ending on its own, with the
    /// reply for the last second of audio still to come.
    private struct DrainingConnection {
        let transport: GeminiRealtimeTransport
        let receiveTask: Task<Void, Never>?
        var pendingInterim: String?
        var heldDeltas: [TranscriptDelta] = []
        var timeoutTask: Task<Void, Never>?
    }

    /// Used when goAway arrives without a readable `timeLeft`.
    private static let defaultGoAwayGrace: Duration = .seconds(30)
    private static let maxRotationAttempts = 3
    private static let rotationRetryDelay: Duration = .seconds(1)

    private let model: String
    private let transportForTesting: GeminiRealtimeTransport?
    private let transportFactoryForTesting: (@Sendable () -> GeminiRealtimeTransport)?
    private let startupOperationForTesting: (@Sendable () async throws -> Void)?
    private let tokenOperation: @Sendable () async throws -> String
    private let authenticateInjectedTransport: Bool
    private let startupDeadline: Duration
    private let audioStreamEndTimeout: Duration
    private let rotationDrainTimeout: Duration
    private var transport: GeminiRealtimeTransport?
    private var continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var framing: [UUID: Framing] = [:]
    private var sessionGeneration: UInt64 = 0
    private var sessionLanguage: String?
    /// Last interim hypothesis from `transport`; nil once it finalizes.
    private var activeInterim: String?
    private var pendingRotation: PendingRotation?
    private var draining: DrainingConnection?

    /// Reaches Gemini Live with this Mac's key, or with single-use tokens the
    /// Cadenza server mints from the account's key: one per connection, never
    /// cached, since a token opens exactly one session.
    init(
        access: AIProviderAccess,
        model: String,
        startupDeadline: Duration = .seconds(15),
        mintCredential: (@Sendable (AIProviderAccess, String) async throws -> String)? = nil
    ) {
        if let apiKey = access.directAPIKey {
            self.init(apiKey: apiKey, model: model, startupDeadline: startupDeadline)
            return
        }
        self.init(
            apiKey: "",
            model: model,
            cloudTokenOperation: Self.cloudTokenOperation(access: access, model: model, mint: mintCredential),
            startupDeadline: startupDeadline
        )
    }

    /// Asks Cadenza for a fresh token on every call: each connection and
    /// goAway rotation needs its own, because a minted token opens one session.
    static func cloudTokenOperation(
        access: AIProviderAccess,
        model: String,
        mint: (@Sendable (AIProviderAccess, String) async throws -> String)? = nil
    ) -> @Sendable () async throws -> String {
        let mint = mint ?? { access, model in
            try await CadenzaRealtimeCredentials.mint(access: access, model: model)
        }
        return {
            let token = try await mint(access, model)
            guard GeminiEphemeralToken.isValidName(token) else {
                throw AIServiceError.invalidResponse
            }
            return token
        }
    }

    init(
        apiKey: String,
        model: String,
        cloudTokenOperation: (@Sendable () async throws -> String)? = nil,
        transportForTesting: GeminiRealtimeTransport? = nil,
        transportFactoryForTesting: (@Sendable () -> GeminiRealtimeTransport)? = nil,
        startupOperationForTesting: (@Sendable () async throws -> Void)? = nil,
        tokenOperationForTesting: (@Sendable () async throws -> String)? = nil,
        startupDeadline: Duration = .seconds(15),
        audioStreamEndTimeout: Duration = .seconds(2),
        rotationDrainTimeout: Duration = .seconds(3)
    ) {
        self.model = model
        self.transportForTesting = transportForTesting
        self.transportFactoryForTesting = transportFactoryForTesting
        self.startupOperationForTesting = startupOperationForTesting
        if let tokenOperationForTesting {
            self.tokenOperation = tokenOperationForTesting
            self.authenticateInjectedTransport = true
        } else if let cloudTokenOperation {
            self.tokenOperation = cloudTokenOperation
            self.authenticateInjectedTransport = false
        } else {
            let tokenProvider = GeminiEphemeralTokenProvider(apiKey: apiKey)
            self.tokenOperation = {
                try await tokenProvider.token()
            }
            self.authenticateInjectedTransport = false
        }
        self.startupDeadline = startupDeadline
        self.audioStreamEndTimeout = audioStreamEndTimeout
        self.rotationDrainTimeout = rotationDrainTimeout
    }

    // MARK: - Real-time Session

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        guard transport == nil else {
            throw TranscriptionError.apiError("Gemini realtime session is already active")
        }
        try GeminiRealtimeHandshake.validateModel(model)
        sessionGeneration &+= 1
        let generation = sessionGeneration
        sessionLanguage = language
        framing = [:]
        activeInterim = nil

        do {
            return try await HardAsyncDeadline.run(for: startupDeadline) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.startSessionAttempt(
                    language: language,
                    generation: generation
                )
            }
        } catch {
            tearDownCurrentSession(matching: generation)
            throw error
        }
    }

    private func startSessionAttempt(
        language: String?,
        generation: UInt64
    ) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {

        if let injectedTransport = transportFactoryForTesting?() ?? transportForTesting {
            transport = injectedTransport
            do {
                if authenticateInjectedTransport {
                    _ = try await provisionEphemeralToken()
                }
                try await startupOperationForTesting?()
                try ensureCurrentSession(generation, transport: injectedTransport)
                return makeTranscriptStream(generation: generation, transport: injectedTransport)
            } catch {
                tearDownCurrentSession(matching: generation, transport: injectedTransport)
                throw error
            }
        }

        let ephemeralToken = try await provisionEphemeralToken()
        try ensureCurrentGeneration(generation)

        let (conn, sessionTransport) = Self.makeSocket()
        self.transport = sessionTransport

        do {
            try await connectLiveSocket(
                conn,
                transport: sessionTransport,
                generation: generation,
                token: ephemeralToken,
                language: language
            )
            return makeTranscriptStream(generation: generation, transport: sessionTransport)
        } catch {
            tearDownCurrentSession(matching: generation, transport: sessionTransport)
            throw error
        }
    }

    /// Raw TCP + TLS with HTTP/1.1 ALPN only. There is no WebSocket in the
    /// protocol stack; framing is handled manually.
    private nonisolated static func makeSocket() -> (NWConnection, GeminiRealtimeTransport) {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let conn = NWConnection(
            host: NWEndpoint.Host(GeminiRealtimeHandshake.host),
            port: 443,
            using: params
        )
        return (conn, GeminiRealtimeTransport(connection: conn))
    }

    /// TCP connect, WebSocket upgrade, then the Live setup exchange. Shared by
    /// the first connection and every goAway replacement.
    private func connectLiveSocket(
        _ conn: NWConnection,
        transport: GeminiRealtimeTransport,
        generation: UInt64,
        token: String,
        language: String?
    ) async throws {
        // Connect with 10-second timeout
        try await connectWithTimeout(conn, seconds: 10)
        conn.stateUpdateHandler = nil
        try ensureOwnedConnection(generation, transport: transport)
        RealtimeDebugLog.shared.append("Gemini: TCP connected")

        // WebSocket upgrade handshake with the correct path
        try await performUpgrade(
            transport,
            generation: generation,
            token: token
        )
        RealtimeDebugLog.shared.append("Gemini: WS upgraded")

        try await performSetup(on: transport, generation: generation, language: language)
    }

    /// Send the setup message and wait for setupComplete. A connection carries
    /// no audio until this returns.
    private func performSetup(
        on transport: GeminiRealtimeTransport,
        generation: UInt64,
        language: String?
    ) async throws {
        let setupJSON = buildSetupConfig(language: language)
        let setupData = try JSONSerialization.data(withJSONObject: setupJSON)
        try await sendTextFrame(setupData, using: transport)
        try ensureOwnedConnection(generation, transport: transport)
        RealtimeDebugLog.shared.append("Gemini: sent setup config")

        let setupResponse = try await receiveTextFrame(
            generation: generation,
            transport: transport
        )
        try ensureOwnedConnection(generation, transport: transport)
        try GeminiRealtimeHandshake.validateSetupAcknowledgement(setupResponse)
        RealtimeDebugLog.shared.append("Gemini: received setup response")
    }

    private func provisionEphemeralToken() async throws -> String {
        do {
            let token = try await tokenOperation()
            guard GeminiEphemeralToken.isValidName(token) else {
                throw GeminiEphemeralTokenError.invalidToken
            }
            return token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiEphemeralTokenError.requestFailed
        }
    }

    /// Sample rate declared to Gemini for every audio chunk. Capture hands
    /// `sendAudio` PCM in `AudioConverter.transcriptionFormat` (24 kHz mono
    /// Int16); Gemini Live resamples server-side from whatever rate the
    /// mimeType declares, so the declaration must track the capture format.
    /// A hard-coded 16000 here made Gemini decode 24 kHz audio at two thirds
    /// speed.
    nonisolated static let declaredInputSampleRate = Int(AudioConverter.transcriptionFormat.sampleRate)

    nonisolated static func audioInputMessage(base64Audio: String) -> [String: Any] {
        [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=\(declaredInputSampleRate)",
                    "data": base64Audio
                ]
            ]
        ]
    }

    func sendAudio(_ data: Data) async throws {
        guard let transport else { return }

        let message = Self.audioInputMessage(base64Audio: data.base64EncodedString())
        let jsonData = try JSONSerialization.data(withJSONObject: message)
        do {
            try await sendTextFrame(jsonData, using: transport)
        } catch {
            // A goAway rotation can retire the socket this chunk was queued on
            // before the send completes. The session itself is healthy, so the
            // chunk goes to the replacement instead of surfacing as a fault.
            guard !(error is CancellationError),
                  !Task.isCancelled,
                  let replacement = self.transport,
                  !replacement.matches(transport) else {
                throw error
            }
            try await sendTextFrame(jsonData, using: replacement)
        }
    }

    /// Flush cached audio — Gemini buffers audio and may not return results until this is sent.
    func sendAudioStreamEnd() async throws {
        guard let transport else { return }
        try await sendTextFrame(
            Self.audioStreamEndMessage(),
            using: transport,
            timeout: audioStreamEndTimeout
        )
    }

    private nonisolated static func audioStreamEndMessage() throws -> Data {
        let message: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ]
        return try JSONSerialization.data(withJSONObject: message)
    }

    func stopRealtimeSession() async throws {
        tearDownCurrentSession()
    }

    var _testHasActiveTransport: Bool { transport != nil }
    var _testHasReceiveTask: Bool { receiveTask != nil }
    var _testIsRotating: Bool { pendingRotation != nil || draining != nil }

    private func makeTranscriptStream(
        generation: UInt64,
        transport: GeminiRealtimeTransport
    ) -> AsyncThrowingStream<TranscriptDelta, Error> {
        let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
        continuation = pair.continuation
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation, transport: transport)
        }
        return pair.stream
    }

    private var hasSessionState: Bool {
        transport != nil || continuation != nil || receiveTask != nil
            || pendingRotation != nil || draining != nil
    }

    /// Ends the session and every socket it owns. With `failure`, the stream
    /// finishes throwing so the manager's reconnect path takes over.
    private func tearDownCurrentSession(failure: Error? = nil) {
        guard hasSessionState else { return }

        sessionGeneration &+= 1
        let exactContinuation = continuation
        let exactReceiveTask = receiveTask
        let exactTransport = transport
        let exactRotation = pendingRotation
        let exactDraining = draining

        continuation = nil
        receiveTask = nil
        transport = nil
        pendingRotation = nil
        draining = nil
        framing = [:]
        activeInterim = nil

        // What the retiring socket and the held-back replacement produced is
        // real transcript; hand it over before the stream closes.
        if let exactDraining {
            releaseDrainOutput(exactDraining, to: exactContinuation)
        }
        if let failure {
            exactContinuation?.finish(throwing: failure)
        } else {
            exactContinuation?.finish()
        }
        exactReceiveTask?.cancel()
        exactTransport?.cancel()
        exactRotation?.task?.cancel()
        exactRotation?.deadlineTask?.cancel()
        exactRotation?.replacement?.cancel()
        exactDraining?.timeoutTask?.cancel()
        exactDraining?.receiveTask?.cancel()
        exactDraining?.transport.cancel()
    }

    private func tearDownCurrentSession(
        matching generation: UInt64,
        transport exactTransport: GeminiRealtimeTransport
    ) {
        guard isCurrentSession(generation, transport: exactTransport) else { return }
        tearDownCurrentSession()
    }

    private func tearDownCurrentSession(matching generation: UInt64) {
        guard sessionGeneration == generation else { return }
        if hasSessionState {
            tearDownCurrentSession()
        } else {
            sessionGeneration &+= 1
            framing = [:]
        }
    }

    /// True only for the socket that currently receives audio.
    private func isCurrentSession(
        _ generation: UInt64,
        transport exactTransport: GeminiRealtimeTransport
    ) -> Bool {
        sessionGeneration == generation
            && transport?.matches(exactTransport) == true
    }

    private func ensureCurrentSession(
        _ generation: UInt64,
        transport exactTransport: GeminiRealtimeTransport
    ) throws {
        guard isCurrentSession(generation, transport: exactTransport) else {
            throw CancellationError()
        }
    }

    /// True for every socket the session still owns: the active one, a
    /// replacement mid-handshake, and a retiring one that is draining.
    private func isOwnedConnection(
        _ generation: UInt64,
        transport exactTransport: GeminiRealtimeTransport
    ) -> Bool {
        guard sessionGeneration == generation else { return false }
        return transport?.matches(exactTransport) == true
            || pendingRotation?.replacement?.matches(exactTransport) == true
            || draining?.transport.matches(exactTransport) == true
    }

    private func ensureOwnedConnection(
        _ generation: UInt64,
        transport exactTransport: GeminiRealtimeTransport
    ) throws {
        guard isOwnedConnection(generation, transport: exactTransport) else {
            throw CancellationError()
        }
    }

    private func ensureCurrentGeneration(_ generation: UInt64) throws {
        guard sessionGeneration == generation else {
            throw CancellationError()
        }
    }

    // MARK: - Connection with Timeout

    private func connectWithTimeout(_ conn: NWConnection, seconds: Int) async throws {
        let pending = GeminiRealtimePendingIO<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                if Task.isCancelled {
                    if pending.resolve(.failure(CancellationError())) {
                        conn.cancel()
                    }
                    return
                }

                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        pending.resolve(.success(()))
                    case .failed(let error):
                        pending.resolve(.failure(error))
                    case .cancelled:
                        pending.resolve(.failure(TranscriptionError.apiError("Connection cancelled")))
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))

                let timeoutTask = Task.detached(priority: .userInitiated) {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                    if pending.resolve(
                        .failure(TranscriptionError.apiError("Connection timed out after \(seconds)s"))
                    ) {
                        conn.cancel()
                    }
                }
                pending.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            if pending.resolve(.failure(CancellationError())) {
                conn.cancel()
            }
        }
    }

    // MARK: - WebSocket Upgrade (Manual HTTP/1.1)

    private func performUpgrade(
        _ transport: GeminiRealtimeTransport,
        generation: UInt64,
        token: String
    ) async throws {
        // Generate random Sec-WebSocket-Key
        var keyBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else {
            throw GeminiRealtimeHandshakeError.invalidRequest
        }
        let wsKey = Data(keyBytes).base64EncodedString()

        let requestData = try GeminiRealtimeHandshake.makeUpgradeRequest(
            token: token,
            webSocketKey: wsKey
        )

        try await rawSend(
            transport,
            data: requestData,
            timeout: .seconds(10)
        )
        try ensureOwnedConnection(generation, transport: transport)

        var accumulator = GeminiRealtimeUpgradeHeaderAccumulator()
        while true {
            let chunk = try await rawReceive(
                transport,
                maxLength: accumulator.remainingCapacity
            )
            try ensureOwnedConnection(generation, transport: transport)
            if let result = try accumulator.append(chunk) {
                try GeminiRealtimeHandshake.validateUpgradeResponseHeader(
                    result.header,
                    webSocketKey: wsKey
                )
                framing[transport.id] = Framing(receiveBuffer: result.remainder)
                return
            }
        }
    }

    // MARK: - Raw Network I/O

    private func rawSend(
        _ transport: GeminiRealtimeTransport,
        data: Data,
        timeout: Duration
    ) async throws {
        let pending = GeminiRealtimePendingIO<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                if Task.isCancelled {
                    if pending.resolve(.failure(CancellationError())) {
                        transport.cancel()
                    }
                    return
                }

                transport.send(data) { error in
                    if let error {
                        pending.resolve(.failure(error))
                    } else {
                        pending.resolve(.success(()))
                    }
                }

                let timeoutTask = Task.detached(priority: .userInitiated) {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    if pending.resolve(
                        .failure(TranscriptionError.apiError("Gemini realtime send timed out"))
                    ) {
                        transport.cancel()
                    }
                }
                pending.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            if pending.resolve(.failure(CancellationError())) {
                transport.cancel()
            }
        }
    }

    private func rawReceive(
        _ transport: GeminiRealtimeTransport,
        maxLength: Int
    ) async throws -> Data {
        let pending = GeminiRealtimePendingIO<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                if Task.isCancelled {
                    if pending.resolve(.failure(CancellationError())) {
                        transport.cancel()
                    }
                    return
                }

                transport.receive(maxLength: maxLength) { data, error in
                    if let error {
                        pending.resolve(.failure(error))
                    } else if let data, !data.isEmpty {
                        pending.resolve(.success(data))
                    } else {
                        pending.resolve(
                            .failure(TranscriptionError.apiError("Connection closed"))
                        )
                    }
                }
            }
        } onCancel: {
            if pending.resolve(.failure(CancellationError())) {
                transport.cancel()
            }
        }
    }

    private func receiveBuffer(for transport: GeminiRealtimeTransport) -> Data {
        framing[transport.id]?.receiveBuffer ?? Data()
    }

    /// Ensure at least `minBytes` are available in this socket's receive buffer.
    private func bufferAtLeast(
        _ minBytes: Int,
        generation: UInt64,
        transport: GeminiRealtimeTransport
    ) async throws {
        guard minBytes >= 0,
              minBytes <= GeminiWebSocketFrameHeader.maximumPayloadBytes
                + GeminiRealtimeUpgradeHeaderAccumulator.maximumHeaderBytes else {
            throw GeminiWebSocketProtocolError.messageTooLarge
        }
        while receiveBuffer(for: transport).count < minBytes {
            try Task.checkCancellation()
            try ensureOwnedConnection(generation, transport: transport)
            let missingBytes = minBytes - receiveBuffer(for: transport).count
            let chunk = try await rawReceive(
                transport,
                maxLength: min(65_536, missingBytes)
            )
            try ensureOwnedConnection(generation, transport: transport)
            let maximumBufferedBytes = GeminiWebSocketFrameHeader.maximumPayloadBytes
                + GeminiRealtimeUpgradeHeaderAccumulator.maximumHeaderBytes
            guard chunk.count <= maximumBufferedBytes - receiveBuffer(for: transport).count else {
                throw GeminiWebSocketProtocolError.messageTooLarge
            }
            framing[transport.id, default: Framing()].receiveBuffer.append(chunk)
        }
    }

    // MARK: - WebSocket Frame Send

    private func sendTextFrame(
        _ data: Data,
        using transport: GeminiRealtimeTransport,
        timeout: Duration = .seconds(10)
    ) async throws {
        try await sendFrame(
            opcode: 0x01,
            payload: data,
            using: transport,
            timeout: timeout
        )
    }

    private func sendFrame(
        opcode: UInt8,
        payload: Data,
        using transport: GeminiRealtimeTransport,
        timeout: Duration = .seconds(10)
    ) async throws {
        let isControlFrame = (opcode & 0x08) != 0
        guard [0x01, 0x08, 0x09, 0x0A].contains(opcode),
              !isControlFrame || payload.count <= 125 else {
            throw GeminiWebSocketProtocolError.invalidFrame
        }
        var frame = Data()
        frame.reserveCapacity(payload.count + 14)

        // Byte 0: FIN=1 + opcode
        frame.append(0x80 | opcode)

        // Byte 1: MASK=1 + payload length
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> i) & 0xFF))
            }
        }

        // 4-byte random masking key (required for client → server)
        var maskKey = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, maskKey.count, &maskKey) == errSecSuccess else {
            throw GeminiWebSocketProtocolError.invalidFrame
        }
        frame.append(contentsOf: maskKey)

        // Masked payload
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ maskKey[i % 4])
        }

        try await rawSend(transport, data: frame, timeout: timeout)
    }

    // MARK: - WebSocket Frame Receive

    /// Read one complete WebSocket text message. Control frames may be
    /// interleaved while a fragmented message is being assembled.
    private func receiveTextFrame(
        generation: UInt64,
        transport: GeminiRealtimeTransport
    ) async throws -> String {
        while true {
            try ensureOwnedConnection(generation, transport: transport)
            try await bufferAtLeast(2, generation: generation, transport: transport)
            let extendedHeaderBytes: Int
            switch receiveBuffer(for: transport)[1] & 0x7F {
            case 126:
                extendedHeaderBytes = 4
            case 127:
                extendedHeaderBytes = 10
            default:
                extendedHeaderBytes = 2
            }
            try await bufferAtLeast(
                extendedHeaderBytes,
                generation: generation,
                transport: transport
            )
            let header: GeminiWebSocketFrameHeader?
            do {
                header = try GeminiWebSocketFrameHeader.parse(from: receiveBuffer(for: transport))
            } catch {
                // Only the framing bits: FIN, RSV, opcode, mask, length marker.
                let bits = receiveBuffer(for: transport).prefix(2)
                    .map { String(format: "%02X", $0) }
                    .joined(separator: " ")
                RealtimeDebugLog.shared.append("Gemini: rejected frame header \(bits)")
                throw error
            }
            guard let header else {
                throw GeminiWebSocketProtocolError.invalidFrame
            }
            try await bufferAtLeast(
                header.totalFrameBytes,
                generation: generation,
                transport: transport
            )
            let buffered = receiveBuffer(for: transport)
            let payload = Data(buffered[header.headerBytes..<header.totalFrameBytes])
            framing[transport.id, default: Framing()].receiveBuffer = Data(
                buffered.dropFirst(header.totalFrameBytes)
            )
            let fragmentedTextBuffer = framing[transport.id]?.fragmentedTextBuffer

            switch header.opcode {
            case 0x09: // Ping → reply with Pong
                try await sendFrame(
                    opcode: 0x0A,
                    payload: payload,
                    using: transport
                )
                continue
            case 0x0A: // Pong — ignore
                continue
            case 0x08: // Close
                throw TranscriptionError.apiError(parseCloseFrame(payload))
            case 0x01, 0x02: // Text, or binary: Gemini Live sends its JSON in
                // binary frames. Either way the payload must decode as UTF-8.
                guard fragmentedTextBuffer == nil else {
                    throw GeminiWebSocketProtocolError.invalidFrame
                }
                if header.isFinal {
                    return try decodeTextMessage(payload)
                }
                framing[transport.id, default: Framing()].fragmentedTextBuffer = payload
            case 0x00: // Continuation
                guard var fragmentedTextBuffer else {
                    throw GeminiWebSocketProtocolError.invalidFrame
                }
                guard payload.count <= GeminiWebSocketFrameHeader.maximumPayloadBytes
                    - fragmentedTextBuffer.count else {
                    throw GeminiWebSocketProtocolError.messageTooLarge
                }
                fragmentedTextBuffer.append(payload)
                if header.isFinal {
                    framing[transport.id]?.fragmentedTextBuffer = nil
                    return try decodeTextMessage(fragmentedTextBuffer)
                }
                framing[transport.id, default: Framing()].fragmentedTextBuffer = fragmentedTextBuffer
            default:
                RealtimeDebugLog.shared.append(
                    "Gemini: rejected frame with opcode \(header.opcode)"
                )
                throw GeminiWebSocketProtocolError.invalidFrame
            }
        }
    }

    private func decodeTextMessage(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            RealtimeDebugLog.shared.append("Gemini: rejected a message that is not UTF-8")
            throw GeminiWebSocketProtocolError.invalidFrame
        }
        return text
    }

    // MARK: - Receive Loop

    private func receiveLoop(
        generation: UInt64,
        transport: GeminiRealtimeTransport
    ) async {
        defer {
            if isCurrentSession(generation, transport: transport) {
                receiveTask = nil
            }
        }
        do {
            while isOwnedConnection(generation, transport: transport) {
                let text = try await receiveTextFrame(
                    generation: generation,
                    transport: transport
                )
                try ensureOwnedConnection(generation, transport: transport)
                try handleMessage(text, generation: generation, transport: transport)
            }
        } catch {
            guard sessionGeneration == generation else { return }
            if draining?.transport.matches(transport) == true {
                // The retiring socket closing or erroring just ends its drain;
                // the session already runs on the replacement.
                finishDrain(generation: generation, retiring: transport, reason: .closed)
                return
            }
            guard isCurrentSession(generation, transport: transport) else { return }
            if error is CancellationError || Task.isCancelled { return }
            tearDownCurrentSession(failure: error)
        }
    }

    private func handleMessage(
        _ text: String,
        generation: UInt64,
        transport: GeminiRealtimeTransport
    ) throws {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        RealtimeDebugLog.shared.append(
            "Gemini: received message with \(json.count) top-level fields"
        )

        if let goAway = GeminiRealtimeGoAway(message: json) {
            handleGoAway(goAway, generation: generation, transport: transport)
        }

        // Handle serverContent — inputTranscription comes here
        let serverContent = (json["serverContent"] ?? json["server_content"]) as? [String: Any]
        if let serverContent {
            let turnComplete = (serverContent["turnComplete"] ?? serverContent["turn_complete"]) as? Bool ?? false

            let transcript = extractTranscript(from: serverContent, turnComplete: turnComplete)
            if let transcript {
                RealtimeDebugLog.shared.append(
                    "Gemini: yielded \(transcript.text.utf8.count) transcript bytes"
                        + (transcript.isFinal ? " (final)" : " (interim)")
                )
                deliver(
                    TranscriptDelta(
                        text: transcript.text,
                        isFinal: transcript.isFinal,
                        language: nil,
                        replacesHypothesis: usesDedicatedTranscription
                    ),
                    generation: generation,
                    transport: transport
                )
            } else {
                NSLog(
                    "[GeminiRealtime] serverContent had %d fields without a transcript",
                    serverContent.count
                )
                RealtimeDebugLog.shared.append(
                    "Gemini: serverContent had \(serverContent.count) fields without a transcript"
                )
            }
        }

        if json["error"] != nil {
            throw TranscriptionError.apiError("Gemini realtime request failed")
        }
    }

    /// Route one delta by the socket it came from. The retiring socket's text
    /// covers earlier audio, so it goes out at once; the replacement's waits
    /// until the retiring socket is done.
    private func deliver(
        _ delta: TranscriptDelta,
        generation: UInt64,
        transport: GeminiRealtimeTransport
    ) {
        guard sessionGeneration == generation else { return }
        if var retiring = draining, retiring.transport.matches(transport) {
            retiring.pendingInterim = delta.isFinal ? nil : delta.text
            draining = retiring
            continuation?.yield(delta)
            return
        }
        guard isCurrentSession(generation, transport: transport) else { return }
        activeInterim = delta.isFinal ? nil : delta.text
        if var retiring = draining {
            retiring.heldDeltas.append(delta)
            draining = retiring
            return
        }
        continuation?.yield(delta)
    }

    // MARK: - goAway Rotation

    private func handleGoAway(
        _ goAway: GeminiRealtimeGoAway,
        generation: UInt64,
        transport retiring: GeminiRealtimeTransport
    ) {
        // A notice from a socket that is already retiring, or a repeat while
        // its replacement is being dialed, needs nothing new.
        guard isCurrentSession(generation, transport: retiring),
              pendingRotation == nil else { return }
        if let previous = draining {
            // Rotations are about ten minutes apart and a drain lasts seconds;
            // settle it now rather than juggle three sockets.
            finishDrain(generation: generation, retiring: previous.transport, reason: .superseded)
        }

        let grace = goAway.timeLeft ?? Self.defaultGoAwayGrace
        RealtimeDebugLog.shared.append("Gemini: goAway received, \(grace) left; opening replacement")

        var rotation = PendingRotation(retiring: retiring)
        rotation.deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            await self?.rotationDeadlineElapsed(generation: generation, retiring: retiring)
        }
        rotation.task = Task { [weak self] in
            await self?.runRotation(generation: generation, retiring: retiring)
        }
        pendingRotation = rotation
    }

    private func isRotationPending(
        _ generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) -> Bool {
        isCurrentSession(generation, transport: retiring)
            && pendingRotation?.retiring.matches(retiring) == true
    }

    private func runRotation(
        generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) async {
        for attempt in 1...Self.maxRotationAttempts {
            if attempt > 1 {
                do {
                    try await Task.sleep(for: Self.rotationRetryDelay)
                } catch {
                    return
                }
            }
            guard isRotationPending(generation, retiring: retiring) else { return }
            do {
                let replacement = try await HardAsyncDeadline.run(for: startupDeadline) { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.openReplacement(generation: generation, retiring: retiring)
                }
                adoptReplacement(replacement, generation: generation, retiring: retiring)
                return
            } catch {
                guard isRotationPending(generation, retiring: retiring) else { return }
                abandonReplacement(generation: generation, retiring: retiring)
                RealtimeDebugLog.shared.append("Gemini: replacement attempt \(attempt) failed")
            }
        }
        // The retiring socket keeps working until the goAway deadline, which
        // hands the session to the ordinary failure path.
        RealtimeDebugLog.shared.append("Gemini: no replacement; keeping the retiring connection until its deadline")
    }

    /// Dial and set up a replacement socket. Audio stays on `retiring` until
    /// this returns, i.e. until the replacement acknowledged setup.
    private func openReplacement(
        generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) async throws -> GeminiRealtimeTransport {
        let language = sessionLanguage
        if transportForTesting != nil || transportFactoryForTesting != nil {
            // Injected sockets skip TCP and the upgrade, but a replacement
            // still runs the setup exchange: its acknowledgement is what makes
            // moving audio safe.
            guard let transportFactoryForTesting else {
                throw TranscriptionError.apiError("No replacement Gemini test transport")
            }
            let replacement = transportFactoryForTesting()
            try registerReplacement(replacement, generation: generation, retiring: retiring)
            if authenticateInjectedTransport {
                _ = try await provisionEphemeralToken()
                try ensureOwnedConnection(generation, transport: replacement)
            }
            try await performSetup(on: replacement, generation: generation, language: language)
            return replacement
        }

        let token = try await provisionEphemeralToken()
        let (conn, replacement) = Self.makeSocket()
        try registerReplacement(replacement, generation: generation, retiring: retiring)
        try await connectLiveSocket(
            conn,
            transport: replacement,
            generation: generation,
            token: token,
            language: language
        )
        return replacement
    }

    /// Record the replacement before its first suspension so teardown and the
    /// goAway deadline can cancel it.
    private func registerReplacement(
        _ replacement: GeminiRealtimeTransport,
        generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) throws {
        guard isRotationPending(generation, retiring: retiring) else {
            throw CancellationError()
        }
        pendingRotation?.replacement = replacement
    }

    private func abandonReplacement(
        generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) {
        guard isRotationPending(generation, retiring: retiring),
              let replacement = pendingRotation?.replacement else { return }
        pendingRotation?.replacement = nil
        framing[replacement.id] = nil
        replacement.cancel()
    }

    /// Move audio to the ready replacement and start draining the retiring
    /// socket. The consumer's stream carries on untouched.
    private func adoptReplacement(
        _ replacement: GeminiRealtimeTransport,
        generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) {
        guard isRotationPending(generation, retiring: retiring),
              pendingRotation?.replacement?.matches(replacement) == true else {
            framing[replacement.id] = nil
            replacement.cancel()
            return
        }
        pendingRotation?.deadlineTask?.cancel()
        pendingRotation = nil

        let drainTimeout = rotationDrainTimeout
        var retired = DrainingConnection(
            transport: retiring,
            receiveTask: receiveTask,
            pendingInterim: activeInterim
        )
        retired.timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: drainTimeout)
            } catch {
                return
            }
            await self?.finishDrain(generation: generation, retiring: retiring, reason: .timedOut)
        }
        draining = retired
        activeInterim = nil

        transport = replacement
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation, transport: replacement)
        }
        Task { [weak self] in
            await self?.flushRetiring(generation: generation, retiring: retiring)
        }
        RealtimeDebugLog.shared.append("Gemini: audio moved to replacement connection")
    }

    /// audioStreamEnd makes Gemini transcribe what it has buffered instead of
    /// waiting for more speech that will never arrive on this socket.
    private func flushRetiring(
        generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) async {
        do {
            try await sendTextFrame(
                Self.audioStreamEndMessage(),
                using: retiring,
                timeout: audioStreamEndTimeout
            )
        } catch {
            finishDrain(generation: generation, retiring: retiring, reason: .flushFailed)
        }
    }

    /// Why a retiring socket stopped draining, for the realtime debug log.
    private enum DrainEnd: String {
        case closed = "closed by server"
        case timedOut = "drain window elapsed"
        case flushFailed = "flush failed"
        case superseded = "next goAway"
    }

    private func finishDrain(
        generation: UInt64,
        retiring: GeminiRealtimeTransport,
        reason: DrainEnd
    ) {
        guard sessionGeneration == generation,
              let retired = draining,
              retired.transport.matches(retiring) else { return }
        draining = nil
        retired.timeoutTask?.cancel()
        framing[retiring.id] = nil
        releaseDrainOutput(retired, to: continuation)
        Task { [weak self] in
            await self?.closeRetired(retiring, receiveTask: retired.receiveTask)
        }
        RealtimeDebugLog.shared.append("Gemini: retired previous connection (\(reason.rawValue))")
    }

    private func releaseDrainOutput(
        _ retired: DrainingConnection,
        to continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    ) {
        // Close the retiring socket's open segment before any replacement text,
        // or the replacement would continue it: the dedicated model's interim
        // would overwrite it in place, the dialogue model's would append to it.
        // The dedicated model's interim is the whole hypothesis, so it becomes
        // the final text. The dialogue model's is its latest increment, which
        // already ends the segment, so resending it changes no text.
        if let interim = retired.pendingInterim {
            continuation?.yield(TranscriptDelta(
                text: interim,
                isFinal: true,
                language: nil,
                replacesHypothesis: usesDedicatedTranscription
            ))
        }
        for delta in retired.heldDeltas {
            continuation?.yield(delta)
        }
    }

    /// Close code 1000 is the orderly goodbye goAway asks for; a client still
    /// attached at the deadline is aborted with 1008 instead.
    private func closeRetired(
        _ retiring: GeminiRealtimeTransport,
        receiveTask: Task<Void, Never>?
    ) async {
        try? await sendFrame(
            opcode: 0x08,
            payload: Data([0x03, 0xE8]),
            using: retiring,
            timeout: .seconds(1)
        )
        retiring.cancel()
        receiveTask?.cancel()
    }

    private func rotationDeadlineElapsed(
        generation: UInt64,
        retiring: GeminiRealtimeTransport
    ) {
        guard isRotationPending(generation, retiring: retiring) else { return }
        RealtimeDebugLog.shared.append("Gemini: goAway deadline passed without a replacement")
        tearDownCurrentSession(
            failure: TranscriptionError.apiError(
                "Gemini realtime connection expired before a replacement was ready"
            )
        )
    }

    // MARK: - Helpers

    /// gemini-3.5-transcribe-live and successors are dedicated ASR models on
    /// the Live API, not dialogue models whose captions fall out of a side
    /// channel. They take structured language hints, answer in TEXT, and split
    /// interim hypotheses from the authoritative final.
    nonisolated private var usesDedicatedTranscription: Bool {
        GeminiTranscribeInteraction.isTranscribeModel(model)
    }

    /// internal rather than private so the exact setup message each model
    /// family sends is pinned by tests; nothing outside this type calls it.
    nonisolated func buildSetupConfig(language: String?) -> [String: Any] {
        if usesDedicatedTranscription {
            // No system instruction: there is no model to instruct, and the
            // Simplified-vs-Traditional problem the prompt below works around
            // is handled structurally by languageCodes. An empty array means
            // auto-detect, which is also what enables code-switching.
            return ["setup": [
                "model": "models/\(model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": [
                    "languageCodes": GeminiTranscribeInteraction.languageCodes(for: language)
                ]
            ]]
        }

        // Native-audio Live models only support AUDIO responses. Ask Gemini to emit
        // text transcriptions for both the user's input audio and the model output.
        var setupConfig: [String: Any] = [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"]
            ],
            "inputAudioTranscription": [:] as [String: Any],
            "outputAudioTranscription": [:] as [String: Any]
        ]

        // Always provide language hint to avoid wrong script (e.g. Traditional vs Simplified Chinese)
        let langHint: String
        if let language, !language.isEmpty, language != "auto" {
            langHint = language
        } else {
            // Default to Simplified Chinese + English mix (most common use case)
            langHint = "the original spoken language. Use Simplified Chinese (简体中文) for Chinese content, not Traditional Chinese"
        }
        setupConfig["systemInstruction"] = [
            "parts": [["text": "Transcribe audio in \(langHint). Output only the transcription text, no commentary."]]
        ]

        return ["setup": setupConfig]
    }

    /// Pull the transcript out of one `serverContent` frame along with whether
    /// it is authoritative. The two model families disagree about what
    /// `inputTranscription` means: the dedicated ASR emits it once per
    /// utterance as the settled text (interim hypotheses arrive separately),
    /// while the dialogue model streams increments there and signals the end
    /// of a turn out of band.
    nonisolated func extractTranscript(
        from serverContent: [String: Any],
        turnComplete: Bool
    ) -> (text: String, isFinal: Bool)? {
        let inputTranscription = (serverContent["inputTranscription"] ?? serverContent["input_transcription"]) as? [String: Any]
        if let text = extractText(from: inputTranscription) {
            RealtimeDebugLog.shared.append(
                "Gemini: received \(text.utf8.count) input-transcription bytes"
            )
            return (text, usesDedicatedTranscription ? true : turnComplete)
        }

        // Interim hypotheses are whole-utterance rewrites, so they are only
        // read for the model family whose deltas replace rather than append.
        if usesDedicatedTranscription {
            let interim = (serverContent["interimInputTranscription"] ?? serverContent["interim_input_transcription"]) as? [String: Any]
            if let text = extractText(from: interim) {
                RealtimeDebugLog.shared.append(
                    "Gemini: received \(text.utf8.count) interim-transcription bytes"
                )
                return (text, false)
            }
        }

        // Fall back to outputTranscription — some models return transcript through the output channel
        let outputTranscription = (serverContent["outputTranscription"] ?? serverContent["output_transcription"]) as? [String: Any]
        if let text = extractText(from: outputTranscription) {
            RealtimeDebugLog.shared.append(
                "Gemini: received \(text.utf8.count) output-transcription bytes"
            )
            return (text, turnComplete)
        }

        return nil
    }

    nonisolated private func extractText(from container: [String: Any]?) -> String? {
        guard let text = container?["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractModelTurnText(from modelTurn: [String: Any]) -> String? {
        guard let parts = modelTurn["parts"] as? [[String: Any]] else { return nil }

        let texts = parts.compactMap { part -> String? in
            if let text = part["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            let inlineData = (part["inlineData"] ?? part["inline_data"]) as? [String: Any]
            if let text = inlineData?["text"] as? String ?? inlineData?["transcript"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            return nil
        }

        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: " ")
    }

    private func parseCloseFrame(_ payload: Data) -> String {
        guard payload.count >= 2 else {
            return "WebSocket closed by server"
        }

        let code = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
        return "WebSocket closed by server (\(code))"
    }

    // MARK: - File Transcription (not used for realtime)

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        throw TranscriptionError.notSupported("Use GeminiTranscriber for file transcription")
    }
}
