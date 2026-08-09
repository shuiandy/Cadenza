import Foundation

/// Real-time transcription using OpenAI Realtime API over WebSocket.
/// Streams 24kHz mono PCM16 audio and receives incremental transcript deltas.
final class RealtimeTranscriber: TranscriptionService, @unchecked Sendable {
    private actor SessionState {
        private var sessionReady = false
        private var didLogWaitingForSession = false

        func reset() {
            sessionReady = false
            didLogWaitingForSession = false
        }

        func markReady() {
            sessionReady = true
            didLogWaitingForSession = false
        }

        func snapshot() -> (sessionReady: Bool, didLogWaitingForSession: Bool) {
            (sessionReady, didLogWaitingForSession)
        }

        func markWaitingLogged() {
            didLogWaitingForSession = true
        }
    }

    private let apiKey: String
    private let model: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    private let session: URLSession
    private let sessionState = SessionState()
    private var lastCommitAt = Date.distantPast
    private var bytesSinceCommit = 0
    private var loggedEventTypes: Set<String> = []
    private var didLogCommitTooSmall = false

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Real-time Session

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()
        RealtimeDebugLog.shared.append("OpenAI: WS connecting to \(url.absoluteString)")
        await sessionState.reset()
        lastCommitAt = Date()
        bytesSinceCommit = 0
        didLogCommitTooSmall = false

        // Realtime transcription sessions use the nested audio.input schema.
        var transcriptionConfig: [String: Any] = [
            "model": model
        ]
        if let language, !language.isEmpty {
            transcriptionConfig["language"] = language
        }

        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ],
                        "transcription": transcriptionConfig,
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any],
                "include": ["item.input_audio_transcription.logprobs"]
            ] as [String: Any]
        ]

        let configData = try JSONSerialization.data(withJSONObject: sessionConfig)
        let configString = String(data: configData, encoding: .utf8)!
        try await task.send(.string(configString))
        RealtimeDebugLog.shared.append("OpenAI: sent session config")

        // Create stream and start receive loop
        let stream = AsyncThrowingStream<TranscriptDelta, Error> { continuation in
            self.continuation = continuation
            Task { [weak self] in
                await self?.receiveMessages()
            }
        }

        // Wait for session to be ready before returning (so sendAudio won't silently drop chunks)
        for _ in 0..<100 {  // up to 10 seconds
            let state = await sessionState.snapshot()
            if state.sessionReady { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        let finalState = await sessionState.snapshot()
        if !finalState.sessionReady {
            RealtimeDebugLog.shared.append("OpenAI: TIMEOUT waiting for session.created (got \(RealtimeDebugLog.shared.entries.count) events)")
            try await stopRealtimeSession()
            throw TranscriptionError.apiError("OpenAI transcription session timed out waiting for session.created")
        }
        RealtimeDebugLog.shared.append("OpenAI: session ready")

        return stream
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }

        let base64Audio = data.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        try await task.send(.string(jsonString))
        bytesSinceCommit += data.count
    }

    func stopRealtimeSession() async throws {
        if bytesSinceCommit > 0 {
            try? await sendCommitMessage()
            // Give the server a brief chance to emit final transcription deltas for
            // the buffered tail before we close the socket.
            try? await Task.sleep(for: .milliseconds(900))
        }
        continuation?.finish()
        continuation = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session.invalidateAndCancel()  // Release URLSession connection pool and caches
        bytesSinceCommit = 0
    }

    // MARK: - Receive Messages

    private func receiveMessages() async {
        guard let task = webSocketTask else { return }

        do {
            while task.closeCode == .invalid {
                let message = try await task.receive()

                switch message {
                case .string(let text):
                    await handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleMessage(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            if isExpectedShutdownError(error) {
                return
            }
            NSLog("[Cadenza] WS receive error: %@", "\(error)")
            RealtimeDebugLog.shared.append("OpenAI WS ERROR: \(error)")
            continuation?.finish(throwing: error)
        }
    }

    private func isExpectedShutdownError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
            return true
        }

        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }

        return webSocketTask == nil
    }

    private func maybeCommitAudioBuffer(force: Bool) async throws {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastCommitAt)
        let hasEnoughAudio = bytesSinceCommit >= minCommitBytes
        let shouldCommit = (force && hasEnoughAudio)
            || bytesSinceCommit >= commitChunkBytes
            || (elapsed >= commitInterval && hasEnoughAudio)
        guard shouldCommit else { return }

        try await sendCommitMessage()
    }

    private func sendCommitMessage() async throws {
        guard let task = webSocketTask else { return }
        let commitMessage: [String: Any] = ["type": "input_audio_buffer.commit"]
        let commitData = try JSONSerialization.data(withJSONObject: commitMessage)
        let commitString = String(data: commitData, encoding: .utf8)!
        try await task.send(.string(commitString))
        lastCommitAt = Date()
        bytesSinceCommit = 0
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        NSLog("[RealtimeTranscriber] received event: %@", type)
        RealtimeDebugLog.shared.append("OpenAI: \(type)")

        switch type {
        case "transcription_session.created", "session.created":
            await sessionState.markReady()

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
            continuation?.finish(throwing: TranscriptionError.apiError(message))

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
