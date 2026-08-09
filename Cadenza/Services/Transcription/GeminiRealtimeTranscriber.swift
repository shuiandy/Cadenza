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
    private let identity = UUID()

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
        identity == other.identity
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

/// Real-time transcription using Gemini Multimodal Live API over WebSocket.
/// Uses raw NWConnection (TCP + TLS) with manual WebSocket handshake & framing
/// to force HTTP/1.1 and control the request URI path.
actor GeminiRealtimeTranscriber: TranscriptionService {
    private let model: String
    private let transportForTesting: GeminiRealtimeTransport?
    private let transportFactoryForTesting: (@Sendable () -> GeminiRealtimeTransport)?
    private let startupOperationForTesting: (@Sendable () async throws -> Void)?
    private let tokenOperation: @Sendable () async throws -> String
    private let authenticateInjectedTransport: Bool
    private let startupDeadline: Duration
    private let audioStreamEndTimeout: Duration
    private var connection: NWConnection?
    private var transport: GeminiRealtimeTransport?
    private var continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var receiveBuffer = Data()
    private var fragmentedTextBuffer: Data?
    private var sessionGeneration: UInt64 = 0

    init(
        apiKey: String,
        model: String,
        transportForTesting: GeminiRealtimeTransport? = nil,
        transportFactoryForTesting: (@Sendable () -> GeminiRealtimeTransport)? = nil,
        startupOperationForTesting: (@Sendable () async throws -> Void)? = nil,
        tokenOperationForTesting: (@Sendable () async throws -> String)? = nil,
        startupDeadline: Duration = .seconds(15),
        audioStreamEndTimeout: Duration = .seconds(2)
    ) {
        self.model = model
        self.transportForTesting = transportForTesting
        self.transportFactoryForTesting = transportFactoryForTesting
        self.startupOperationForTesting = startupOperationForTesting
        if let tokenOperationForTesting {
            self.tokenOperation = tokenOperationForTesting
            self.authenticateInjectedTransport = true
        } else {
            let tokenProvider = GeminiEphemeralTokenProvider(apiKey: apiKey)
            self.tokenOperation = {
                try await tokenProvider.token()
            }
            self.authenticateInjectedTransport = false
        }
        self.startupDeadline = startupDeadline
        self.audioStreamEndTimeout = audioStreamEndTimeout
    }

    // MARK: - Real-time Session

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        guard transport == nil else {
            throw TranscriptionError.apiError("Gemini realtime session is already active")
        }
        try GeminiRealtimeHandshake.validateModel(model)
        sessionGeneration &+= 1
        let generation = sessionGeneration
        receiveBuffer = Data()
        fragmentedTextBuffer = nil

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

        // Configure TLS with HTTP/1.1 ALPN only
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30

        // Raw TCP + TLS — NO WebSocket in protocol stack (we handle framing manually)
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        let conn = NWConnection(
            host: NWEndpoint.Host(GeminiRealtimeHandshake.host),
            port: 443,
            using: params
        )
        let sessionTransport = GeminiRealtimeTransport(connection: conn)
        self.connection = conn
        self.transport = sessionTransport

        do {
            // Connect with 10-second timeout
            try await connectWithTimeout(conn, seconds: 10)
            conn.stateUpdateHandler = nil
            try ensureCurrentSession(generation, transport: sessionTransport)
            RealtimeDebugLog.shared.append("Gemini: TCP connected")

            // WebSocket upgrade handshake with the correct path
            try await performUpgrade(
                sessionTransport,
                generation: generation,
                token: ephemeralToken
            )
            RealtimeDebugLog.shared.append("Gemini: WS upgraded")

            // Send Gemini setup message as a WebSocket text frame
            let setupJSON = buildSetupConfig(language: language)
            let setupData = try JSONSerialization.data(withJSONObject: setupJSON)
            try await sendTextFrame(setupData, using: sessionTransport)
            try ensureCurrentSession(generation, transport: sessionTransport)
            RealtimeDebugLog.shared.append("Gemini: sent setup config")

            // Wait for setupComplete response
            let setupResponse = try await receiveTextFrame(
                generation: generation,
                transport: sessionTransport
            )
            try ensureCurrentSession(generation, transport: sessionTransport)
            try GeminiRealtimeHandshake.validateSetupAcknowledgement(setupResponse)
            RealtimeDebugLog.shared.append("Gemini: received setup response")

            return makeTranscriptStream(generation: generation, transport: sessionTransport)
        } catch {
            tearDownCurrentSession(matching: generation, transport: sessionTransport)
            throw error
        }
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

    func sendAudio(_ data: Data) async throws {
        guard let transport else { return }

        let base64Audio = data.base64EncodedString()
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": base64Audio
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        try await sendTextFrame(jsonData, using: transport)
    }

    /// Flush cached audio — Gemini buffers audio and may not return results until this is sent.
    func sendAudioStreamEnd() async throws {
        guard let transport else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: message)
        try await sendTextFrame(
            jsonData,
            using: transport,
            timeout: audioStreamEndTimeout
        )
    }

    func stopRealtimeSession() async throws {
        tearDownCurrentSession()
    }

    var _testHasActiveTransport: Bool { transport != nil }
    var _testHasReceiveTask: Bool { receiveTask != nil }

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

    private func tearDownCurrentSession() {
        guard transport != nil || continuation != nil || receiveTask != nil || connection != nil else {
            return
        }

        sessionGeneration &+= 1
        let exactContinuation = continuation
        let exactReceiveTask = receiveTask
        let exactTransport = transport

        continuation = nil
        receiveTask = nil
        transport = nil
        connection = nil
        receiveBuffer = Data()
        fragmentedTextBuffer = nil

        exactContinuation?.finish()
        exactReceiveTask?.cancel()
        exactTransport?.cancel()
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
        if transport != nil || continuation != nil || receiveTask != nil || connection != nil {
            tearDownCurrentSession()
        } else {
            sessionGeneration &+= 1
            receiveBuffer = Data()
            fragmentedTextBuffer = nil
        }
    }

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
        try ensureCurrentSession(generation, transport: transport)

        var accumulator = GeminiRealtimeUpgradeHeaderAccumulator()
        while true {
            let chunk = try await rawReceive(
                transport,
                maxLength: accumulator.remainingCapacity
            )
            try ensureCurrentSession(generation, transport: transport)
            if let result = try accumulator.append(chunk) {
                try GeminiRealtimeHandshake.validateUpgradeResponseHeader(
                    result.header,
                    webSocketKey: wsKey
                )
                receiveBuffer = result.remainder
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

    /// Ensure at least `minBytes` are available in the receive buffer.
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
        while receiveBuffer.count < minBytes {
            try Task.checkCancellation()
            try ensureCurrentSession(generation, transport: transport)
            let missingBytes = minBytes - receiveBuffer.count
            let chunk = try await rawReceive(
                transport,
                maxLength: min(65_536, missingBytes)
            )
            try ensureCurrentSession(generation, transport: transport)
            let maximumBufferedBytes = GeminiWebSocketFrameHeader.maximumPayloadBytes
                + GeminiRealtimeUpgradeHeaderAccumulator.maximumHeaderBytes
            guard chunk.count <= maximumBufferedBytes - receiveBuffer.count else {
                throw GeminiWebSocketProtocolError.messageTooLarge
            }
            receiveBuffer.append(chunk)
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
            try await bufferAtLeast(2, generation: generation, transport: transport)
            let extendedHeaderBytes: Int
            switch receiveBuffer[1] & 0x7F {
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
            let header = try GeminiWebSocketFrameHeader.parse(from: receiveBuffer)
            guard let header else {
                throw GeminiWebSocketProtocolError.invalidFrame
            }
            try await bufferAtLeast(
                header.totalFrameBytes,
                generation: generation,
                transport: transport
            )
            let payload = Data(receiveBuffer[header.headerBytes..<header.totalFrameBytes])
            receiveBuffer = Data(receiveBuffer.dropFirst(header.totalFrameBytes))

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
            case 0x01: // Text
                guard fragmentedTextBuffer == nil else {
                    throw GeminiWebSocketProtocolError.invalidFrame
                }
                if header.isFinal {
                    return try decodeTextMessage(payload)
                }
                fragmentedTextBuffer = payload
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
                    self.fragmentedTextBuffer = nil
                    return try decodeTextMessage(fragmentedTextBuffer)
                }
                self.fragmentedTextBuffer = fragmentedTextBuffer
            case 0x02: // Gemini realtime messages must be UTF-8 JSON text.
                throw GeminiWebSocketProtocolError.invalidFrame
            default:
                throw GeminiWebSocketProtocolError.invalidFrame
            }
        }
    }

    private func decodeTextMessage(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
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
            while isCurrentSession(generation, transport: transport) {
                let text = try await receiveTextFrame(
                    generation: generation,
                    transport: transport
                )
                try ensureCurrentSession(generation, transport: transport)
                try handleMessage(text)
            }
        } catch {
            guard isCurrentSession(generation, transport: transport) else { return }
            if error is CancellationError || Task.isCancelled { return }
            let exactContinuation = continuation
            exactContinuation?.finish(throwing: error)
            tearDownCurrentSession(matching: generation, transport: transport)
        }
    }

    private func handleMessage(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        RealtimeDebugLog.shared.append(
            "Gemini: received message with \(json.count) top-level fields"
        )

        // Handle serverContent — inputTranscription comes here
        let serverContent = (json["serverContent"] ?? json["server_content"]) as? [String: Any]
        if let serverContent {
            let turnComplete = (serverContent["turnComplete"] ?? serverContent["turn_complete"]) as? Bool ?? false

            if let transcriptText = extractTranscriptText(from: serverContent), !transcriptText.isEmpty {
                RealtimeDebugLog.shared.append(
                    "Gemini: yielded \(transcriptText.utf8.count) transcript bytes"
                )
                continuation?.yield(TranscriptDelta(
                    text: transcriptText,
                    isFinal: turnComplete,
                    language: nil
                ))
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

    // MARK: - Helpers

    private func buildSetupConfig(language: String?) -> [String: Any] {
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

    private func extractTranscriptText(from serverContent: [String: Any]) -> String? {
        // Prefer inputTranscription (speech-to-text of the user's audio)
        let inputTranscription = (serverContent["inputTranscription"] ?? serverContent["input_transcription"]) as? [String: Any]
        if let text = extractText(from: inputTranscription) {
            RealtimeDebugLog.shared.append(
                "Gemini: received \(text.utf8.count) input-transcription bytes"
            )
            return text
        }

        // Fall back to outputTranscription — some models return transcript through the output channel
        let outputTranscription = (serverContent["outputTranscription"] ?? serverContent["output_transcription"]) as? [String: Any]
        if let text = extractText(from: outputTranscription) {
            RealtimeDebugLog.shared.append(
                "Gemini: received \(text.utf8.count) output-transcription bytes"
            )
            return text
        }

        return nil
    }

    private func extractText(from container: [String: Any]?) -> String? {
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
