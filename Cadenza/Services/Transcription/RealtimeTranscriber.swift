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
    private let commitPolicy: LiveCommitPolicy
    private var pauseDetector: PauseDetector
    /// Bytes appended to the server's input buffer so far: the stream offset
    /// that commits and `finalizedAudioBytes` refer to.
    private var appendedBytes = 0
    /// Offsets of sent commits the server has not acknowledged, oldest first.
    private var unacknowledgedCommits: [Int] = []
    /// Acknowledged turns, oldest first, until they and every turn before them
    /// have a transcript.
    private var committedTurns: [CommittedTurn] = []
    private var loggedEventTypes: Set<String> = []
    private var didLogCommitTooSmall = false

    init(
        apiKey: String,
        model: String,
        transportForTesting: OpenAIRealtimeTransport? = nil,
        startupTimeout: Duration = .seconds(10),
        commitPolicy: LiveCommitPolicy = LiveCommitPolicy()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transportForTesting = transportForTesting
        self.startupTimeout = startupTimeout
        self.commitPolicy = commitPolicy
        self.pauseDetector = PauseDetector(
            pauseDuration: commitPolicy.pauseDuration,
            shortPauseDuration: commitPolicy.shortPauseDuration
        )
    }

    private struct CommittedTurn {
        let itemID: String?
        let endOffset: Int
        var isTranscribed = false
    }

    /// Capture's ~21 ms buffers go out whole. Larger blocks, such as audio
    /// replayed after a reconnect, go out 20 ms at a time, so a turn can still
    /// end at the gap where it happened rather than at the end of the block.
    private static let largeBlockBytes = 2_048
    private static let liveSliceBytes = 960

    /// Explicit supported profile; an arbitrary model name isn't a capability.
    private nonisolated var usesLiveTranscription: Bool { model == "gpt-live-transcribe" }

    /// Only the live model's turns are committed here, so only its commits can
    /// be matched to transcripts.
    nonisolated var reportsFinalizedAudio: Bool { usesLiveTranscription }

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
        guard usesLiveTranscription else {
            // Legacy models commit their own turns with server VAD.
            try await appendAudio(data, to: connection)
            guard transport != nil, !isStopping else { return }
            bytesSinceCommit += data.count
            return
        }
        // The live model emits deltas before commit, but needs explicit commits
        // for final transcripts and bounded turns.
        let sliceBytes = data.count > Self.largeBlockBytes ? Self.liveSliceBytes : data.count
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(data.endIndex, start + sliceBytes)
            let slice = data[start..<end]
            try await appendAudio(slice, to: connection)
            guard transport != nil, !isStopping else { return }
            appendedBytes += slice.count
            bytesSinceCommit += slice.count
            pauseDetector.ingest(slice)
            try await maybeCommitAudioBuffer()
            start = end
        }
    }

    private func appendAudio(_ audio: Data, to connection: OpenAIRealtimeTransport) async throws {
        let message: [String: Any] = [
            "type": "input_audio_buffer.append", "audio": audio.base64EncodedString()
        ]
        let json = try JSONSerialization.data(withJSONObject: message)
        try await connection.send(String(decoding: json, as: UTF8.self))
    }

    func stopRealtimeSession() async throws {
        guard !isStopping else { return }
        isStopping = true
        if sessionReady, sessionFailure == nil, bytesSinceCommit >= commitPolicy.minCommitBytes {
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
        let elapsed = Date().timeIntervalSince(lastCommitAt)
        let hasEnoughAudio = bytesSinceCommit >= commitPolicy.minCommitBytes
        let isLongTurn = commitPolicy.shortPauseAfterBytes.map { bytesSinceCommit >= $0 } ?? false
        let shouldCommit = (pauseDetector.hasPause && hasEnoughAudio)
            || (pauseDetector.hasShortPause && isLongTurn)
            || bytesSinceCommit >= commitPolicy.fallbackBytes
            || (elapsed >= commitPolicy.fallbackInterval && hasEnoughAudio)
        guard shouldCommit else { return }

        try await sendCommitMessage()
    }

    private func sendCommitMessage() async throws {
        guard let connection = transport else { return }
        let commitMessage: [String: Any] = ["type": "input_audio_buffer.commit"]
        let commitData = try JSONSerialization.data(withJSONObject: commitMessage)
        let commitString = String(data: commitData, encoding: .utf8)!
        // Registered first: the acknowledgement can be handled before the send
        // call returns to this actor.
        unacknowledgedCommits.append(appendedBytes)
        do {
            try await connection.send(commitString)
        } catch {
            unacknowledgedCommits.removeLast()
            throw error
        }
        lastCommitAt = Date()
        bytesSinceCommit = 0
        pauseDetector.didCommit()
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

        case "input_audio_buffer.committed":
            // The server acknowledges commits in the order they were sent, each
            // with the item its transcript will name (checked against the live
            // service on 2026-09-29). Server VAD commits have no entry here.
            guard !unacknowledgedCommits.isEmpty else { break }
            let endOffset = unacknowledgedCommits.removeFirst()
            committedTurns.append(CommittedTurn(itemID: json["item_id"] as? String, endOffset: endOffset))

        case "conversation.item.input_audio_transcription.delta",
             "response.audio_transcript.delta":
            if let delta = extractTranscriptText(from: json, keys: ["delta", "transcript", "text"]) {
                continuation?.yield(TranscriptDelta(text: delta, isFinal: false, language: extractLanguage(from: json)))
            }

        case "conversation.item.input_audio_transcription.completed",
             "response.audio_transcript.done",
             "response.audio_transcript.completed":
            let finalizedAudioBytes = markTurnTranscribed(itemID: json["item_id"] as? String)
            let transcript = extractTranscriptText(from: json, keys: ["transcript", "text", "delta"])
            // A turn without speech completes with an empty transcript. It still
            // settles that audio, so report it even though there is no text.
            if transcript != nil || finalizedAudioBytes != nil {
                continuation?.yield(TranscriptDelta(
                    text: transcript ?? "",
                    isFinal: true,
                    language: extractLanguage(from: json),
                    finalizedAudioBytes: finalizedAudioBytes
                ))
            }

        case "conversation.item.input_audio_transcription.failed":
            // No text will come for this turn. Treat it as settled: replaying it
            // would also replay every later turn, whose text is already shown.
            if let finalizedAudioBytes = markTurnTranscribed(itemID: json["item_id"] as? String) {
                continuation?.yield(TranscriptDelta(
                    text: "",
                    isFinal: true,
                    language: nil,
                    finalizedAudioBytes: finalizedAudioBytes
                ))
            }

        case "error":
            let errorPayload = json["error"] as? [String: Any]
            if let code = errorPayload?["code"] as? String,
               code == "input_audio_buffer_commit_empty" {
                // That commit created no turn; the next turn's audio covers it.
                if !unacknowledgedCommits.isEmpty {
                    unacknowledgedCommits.removeFirst()
                }
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

    /// Marks the turn for `itemID` transcribed, or the oldest open turn when the
    /// event names no item. Returns the new finalized stream offset when this
    /// settles the oldest open turn, together with any settled turns after it.
    private func markTurnTranscribed(itemID: String?) -> Int? {
        let index = if let itemID {
            committedTurns.firstIndex { $0.itemID == itemID }
        } else {
            committedTurns.firstIndex { !$0.isTranscribed }
        }
        guard let index else { return nil }
        committedTurns[index].isTranscribed = true
        var finalizedAudioBytes: Int?
        while let first = committedTurns.first, first.isTranscribed {
            finalizedAudioBytes = first.endOffset
            committedTurns.removeFirst()
        }
        return finalizedAudioBytes
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
