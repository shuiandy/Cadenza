import Foundation

/// One connection boundary, injectable without credentials or live audio.
struct OpenAIRealtimeTransport: Sendable {
    let send: @Sendable (String) async throws -> Void
    let receive: @Sendable () async throws -> String
    let cancel: @Sendable () -> Void

    static func connect(apiKey: String) -> Self {
        let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()
        return Self(
            send: { try await task.send(.string($0)) },
            receive: {
                switch try await task.receive() {
                case .string(let text): return text
                case .data(let data): return String(decoding: data, as: UTF8.self)
                @unknown default: return ""
                }
            },
            cancel: {
                task.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
            }
        )
    }
}

/// Real-time transcription using OpenAI Realtime API over WebSocket.
/// Each manager attempt owns a fresh, single-use instance.
actor RealtimeTranscriber: TranscriptionService {
    private let apiKey: String
    private let model: String
    private let transportForTesting: OpenAIRealtimeTransport?
    private let startupTimeout: Duration
    private var transport: OpenAIRealtimeTransport?
    private var continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var hasStarted = false
    private var isStopping = false
    private var sessionReady = false
    private var sessionFailure: Error?
    private var lastCommitAt = Date.distantPast
    private var bytesSinceCommit = 0
    private var loggedEventTypes: Set<String> = []
    private var didLogCommitTooSmall = false

    init(
        apiKey: String,
        model: String,
        transportForTesting: OpenAIRealtimeTransport? = nil,
        startupTimeout: Duration = .seconds(10)
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transportForTesting = transportForTesting
        self.startupTimeout = startupTimeout
    }

    /// Explicit supported profile; an arbitrary model name isn't a capability.
    private var usesLiveTranscription: Bool { model == "gpt-live-transcribe" }

    private func sessionConfiguration(language: String?) -> [String: Any] {
        var transcription: [String: Any] = ["model": model]
        if let language, !language.isEmpty, language != "auto" {
            if usesLiveTranscription {
                transcription["languages"] = [language]
            } else {
                transcription["language"] = language
            }
        }
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24000],
            "noise_reduction": ["type": "near_field"],
            "transcription": transcription
        ]
        var session: [String: Any] = ["type": "transcription"]
        if usesLiveTranscription {
            input["turn_detection"] = NSNull()
        } else {
            input["turn_detection"] = [
                "type": "server_vad", "threshold": 0.5,
                "prefix_padding_ms": 300, "silence_duration_ms": 500
            ] as [String: Any]
            session["include"] = ["item.input_audio_transcription.logprobs"]
        }
        session["audio"] = ["input": input]
        return ["type": "session.update", "session": session]
    }

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        guard !hasStarted, !isStopping else { throw CancellationError() }
        hasStarted = true
        try Task.checkCancellation()
        let connection = transportForTesting ?? OpenAIRealtimeTransport.connect(apiKey: apiKey)
        transport = connection
        lastCommitAt = Date()
        let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
        continuation = pair.continuation
        do {
            let config = try JSONSerialization.data(withJSONObject: sessionConfiguration(language: language))
            try await connection.send(String(decoding: config, as: UTF8.self))
            try Task.checkCancellation()
            guard transport != nil else { throw CancellationError() }
            RealtimeDebugLog.shared.append("OpenAI: sent session config")
            receiveTask = Task { [weak self] in
                await self?.receiveMessages(connection)
            }
            let deadline = ContinuousClock.now.advanced(by: startupTimeout)
            while !sessionReady {
                if let sessionFailure { throw sessionFailure }
                guard transport != nil else { throw CancellationError() }
                guard ContinuousClock.now < deadline else {
                    throw TranscriptionError.apiError("OpenAI transcription session timed out waiting for session.updated")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            if let sessionFailure { throw sessionFailure }
            RealtimeDebugLog.shared.append("OpenAI: session configuration accepted")
            return pair.stream
        } catch {
            closeTransport()
            throw error
        }
    }

    func sendAudio(_ data: Data) async throws {
        guard let connection = transport, sessionReady, !isStopping else { return }
        if let sessionFailure { throw sessionFailure }
        let message: [String: Any] = [
            "type": "input_audio_buffer.append", "audio": data.base64EncodedString()
        ]
        let json = try JSONSerialization.data(withJSONObject: message)
        try await connection.send(String(decoding: json, as: UTF8.self))
        guard transport != nil, !isStopping else { return }
        bytesSinceCommit += data.count
        // The live model emits deltas before commit, but needs explicit commits
        // for final transcripts and bounded turns. Legacy models use server VAD.
        if usesLiveTranscription {
            try await maybeCommitAudioBuffer()
        }
    }

    func stopRealtimeSession() async throws {
        guard !isStopping else { return }
        isStopping = true
        if sessionReady, sessionFailure == nil, bytesSinceCommit >= minCommitBytes {
            try? await sendCommitMessage()
            // Keep final deltas available to the manager's bounded quality drain.
            try? await Task.sleep(for: .milliseconds(900))
        }
        closeTransport()
    }

    private func closeTransport() {
        continuation?.finish()
        continuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        let connection = transport
        transport = nil
        connection?.cancel()
        sessionReady = false
        bytesSinceCommit = 0
    }

    private func receiveMessages(_ connection: OpenAIRealtimeTransport) async {
        do {
            while !Task.isCancelled, transport != nil {
                let text = try await connection.receive()
                guard !Task.isCancelled, transport != nil else { return }
                handleMessage(text)
                if sessionFailure != nil { return }
            }
        } catch {
            // Only our own close is expected. A remote ENOTCONN/cancel is still
            // a failure while the connection belongs to the active session.
            guard transport != nil, !Task.isCancelled else { return }
            sessionFailure = error
            RealtimeDebugLog.shared.append("OpenAI: WebSocket receive failed")
            continuation?.finish(throwing: error)
        }
    }

    private func maybeCommitAudioBuffer() async throws {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastCommitAt)
        let hasEnoughAudio = bytesSinceCommit >= minCommitBytes
        let shouldCommit = bytesSinceCommit >= commitChunkBytes
            || (elapsed >= commitInterval && hasEnoughAudio)
        guard shouldCommit else { return }

        try await sendCommitMessage()
    }

    private func sendCommitMessage() async throws {
        guard let connection = transport else { return }
        let commitMessage: [String: Any] = ["type": "input_audio_buffer.commit"]
        let commitData = try JSONSerialization.data(withJSONObject: commitMessage)
        let commitString = String(data: commitData, encoding: .utf8)!
        try await connection.send(commitString)
        lastCommitAt = Date()
        bytesSinceCommit = 0
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        NSLog("[RealtimeTranscriber] received event: %@", type)
        RealtimeDebugLog.shared.append("OpenAI: \(type)")

        switch type {
        case "transcription_session.created", "session.created":
            // Creation precedes validation of our session.update payload.
            break

        case "transcription_session.updated", "session.updated":
            sessionReady = true

        case "conversation.item.input_audio_transcription.delta",
             "response.audio_transcript.delta":
            if let delta = extractTranscriptText(from: json, keys: ["delta", "transcript", "text"]) {
                continuation?.yield(TranscriptDelta(text: delta, isFinal: false, language: extractLanguage(from: json)))
            }

        case "conversation.item.input_audio_transcription.completed",
             "response.audio_transcript.done",
             "response.audio_transcript.completed":
            if let transcript = extractTranscriptText(from: json, keys: ["transcript", "text", "delta"]) {
                continuation?.yield(TranscriptDelta(text: transcript, isFinal: true, language: extractLanguage(from: json)))
            }

        case "error":
            let errorPayload = json["error"] as? [String: Any]
            if let code = errorPayload?["code"] as? String,
               code == "input_audio_buffer_commit_empty" {
                if !didLogCommitTooSmall {
                    didLogCommitTooSmall = true
                    NSLog("[Cadenza] Ignoring small commit warning from realtime API")
                }
                // Non-fatal: keep the session alive.
                break
            }

            let errorDetail = "\(errorPayload ?? json)"
            NSLog("[Cadenza] Realtime API error payload: %@", errorDetail)
            RealtimeDebugLog.shared.append("OpenAI ERROR: \(errorDetail)")
            let message = (errorPayload?["message"] as? String)
                ?? (errorPayload?["type"] as? String)
                ?? "Realtime transcription session failed"
            let error = TranscriptionError.apiError(message)
            sessionFailure = error
            continuation?.finish(throwing: error)

        default:
            if type.lowercased().contains("transcript"),
               let text = extractTranscriptText(from: json, keys: ["delta", "transcript", "text"]),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lower = type.lowercased()
                let isFinal = lower.contains("done")
                    || lower.contains("completed")
                    || lower.contains("final")
                continuation?.yield(TranscriptDelta(text: text, isFinal: isFinal, language: extractLanguage(from: json)))
            }
            logUnknownEventType(type)
            break
        }
    }

    private func extractTranscriptText(from json: [String: Any], keys: [String]) -> String? {
        if let direct = firstString(in: json, keys: keys) { return direct }
        if let item = json["item"] as? [String: Any] {
            if let value = firstString(in: item, keys: keys) { return value }
            if let content = item["content"] as? [[String: Any]] {
                for part in content {
                    if let value = firstString(in: part, keys: keys) { return value }
                }
            }
        }
        if let transcription = json["transcription"] as? [String: Any],
           let value = firstString(in: transcription, keys: keys) {
            return value
        }
        if let data = json["data"] as? [String: Any],
           let value = firstString(in: data, keys: keys) {
            return value
        }
        return nil
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func extractLanguage(from json: [String: Any]) -> String? {
        if let language = json["language"] as? String, !language.isEmpty {
            return language
        }
        if let item = json["item"] as? [String: Any],
           let language = item["language"] as? String, !language.isEmpty {
            return language
        }
        return nil
    }

    private var commitInterval: TimeInterval {
        2.8
    }

    private var commitChunkBytes: Int {
        // ~3s at 24kHz mono PCM16 (48KB/s)
        144_000
    }

    private var minCommitBytes: Int {
        // 24kHz * 2 bytes * ~420ms
        20_000
    }

    private func logUnknownEventType(_ type: String) {
        guard loggedEventTypes.count < 16 else { return }
        guard !loggedEventTypes.contains(type) else { return }
        loggedEventTypes.insert(type)
        NSLog("[Cadenza] Realtime unhandled event type: %@", type)
    }

    // MARK: - File Transcription (not used for realtime, delegates to WhisperTranscriber)

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        throw TranscriptionError.notSupported("Use WhisperTranscriber for file transcription")
    }
}

enum TranscriptionError: Error, LocalizedError {
    case apiError(String)
    case notSupported(String)
    case fileNotFound
    case fileTooLarge
    case permissionDenied

    // Transcription errors cross into alerts, the recording overlay, and
    // detail views as Text(String). Localize at this boundary and keep raw
    // provider/implementation details out of the user-facing description.
    var errorDescription: String? { localizedMessage() }

    /// Convert AVFoundation, CoreML, Speech, or provider-native failures at a
    /// transcription service boundary. The associated diagnostic remains
    /// available for private logs, while `errorDescription` stays stable.
    static func userVisible(from error: Error) -> TranscriptionError {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError
        }
        return .apiError(String(describing: error))
    }

    func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .apiError:
            return LocalizedBundle.string(
                "Transcription failed. Check the selected provider settings and network connection, then try again.",
                locale: locale
            )
        case .notSupported:
            return LocalizedBundle.string(
                "The selected transcription operation isn't supported. Choose another transcription provider in Settings.",
                locale: locale
            )
        case .fileNotFound:
            return LocalizedBundle.string(
                "The audio file for this recording could not be found.",
                locale: locale
            )
        case .fileTooLarge:
            return LocalizedBundle.string(
                "The audio file is too large for the selected transcription provider. Use a shorter recording or choose another provider.",
                locale: locale
            )
        case .permissionDenied:
            return LocalizedBundle.string(
                "Speech Recognition access is required. Enable Cadenza in System Settings → Privacy & Security → Speech Recognition.",
                locale: locale
            )
        }
    }
}
