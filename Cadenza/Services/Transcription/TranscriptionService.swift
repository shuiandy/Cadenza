import Foundation
import os

struct HardAsyncDeadlineExceeded: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        String(localized: "The operation timed out.")
    }
}

private final class HardAsyncDeadlineState<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var terminalResult: Result<Value, Error>?
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

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let continuation = lock.withLock { state -> CheckedContinuation<Value, Error>? in
            guard state.terminalResult == nil else { return nil }
            state.terminalResult = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }
}

/// A hard async deadline that returns even when the operation is suspended in a
/// non-cooperative callback continuation. The losing operation is cancelled on
/// a best-effort basis; its owner remains responsible for exact late cleanup.
enum HardAsyncDeadline {
    static func run<Value: Sendable>(
        for timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let state = HardAsyncDeadlineState<Value>()
        let operationTask = Task.detached(priority: .userInitiated) { [weak state] in
            do {
                let value = try await operation()
                state?.resolve(.success(value))
            } catch {
                state?.resolve(.failure(error))
            }
        }
        let timeoutTask = Task.detached(priority: .userInitiated) { [weak state] in
            do {
                try await Task.sleep(for: timeout)
                state?.resolve(.failure(HardAsyncDeadlineExceeded()))
            } catch {
                // The operation or caller won and cancelled the timer.
            }
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                if Task.isCancelled {
                    state.resolve(.failure(CancellationError()))
                }
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            state.resolve(.failure(CancellationError()))
        }
    }
}

/// Immutable ownership token for one realtime startup/reconnect attempt.
/// Recording identity is intentionally not enough: multiple attempts can race
/// within the same recording.
struct RealtimeAttemptID: Sendable, Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Protocol for transcription backends.
protocol TranscriptionService: Sendable {
    /// Start a real-time transcription session. Returns an async stream of transcript deltas.
    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error>

    /// Send audio data to the active real-time session.
    func sendAudio(_ data: Data) async throws

    /// Stop the real-time session.
    func stopRealtimeSession() async throws

    /// Transcribe an audio file (post-recording). Returns the full transcript.
    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult
}

/// A delta from the real-time transcription stream.
struct TranscriptDelta: Sendable {
    let text: String
    let isFinal: Bool
    let language: String?
    /// True when `text` is a complete hypothesis that supersedes whatever the
    /// stream said last, rather than an increment to append to it. Dedicated
    /// ASR models (Apple's, gemini-3.5-transcribe-live) resend the whole
    /// utterance as it firms up; appending those would duplicate every word.
    let replacesHypothesis: Bool

    init(
        text: String,
        isFinal: Bool,
        language: String?,
        replacesHypothesis: Bool = false
    ) {
        self.text = text
        self.isFinal = isFinal
        self.language = language
        self.replacesHypothesis = replacesHypothesis
    }
}

/// Result from post-recording transcription.
struct TranscriptResult: Sendable {
    let text: String
    let segments: [TranscriptResultSegment]
    let language: String?
    let duration: TimeInterval?
    /// Type-erased WhisperKit [TranscriptionResult] for speaker alignment.
    /// Only populated by LocalWhisperTranscriber. Consumer casts via `as? [TranscriptionResult]`.
    let whisperResults: (any Sendable)?

    init(text: String, segments: [TranscriptResultSegment], language: String?,
         duration: TimeInterval?, whisperResults: (any Sendable)? = nil) {
        self.text = text
        self.segments = segments
        self.language = language
        self.duration = duration
        self.whisperResults = whisperResults
    }
}

struct TranscriptResultSegment: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}
