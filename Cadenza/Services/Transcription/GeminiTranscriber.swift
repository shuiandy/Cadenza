@preconcurrency import AVFoundation
import Foundation
import os

/// Response *shape* only — counts and outcomes, never transcript content.
/// NSLog does not reach the unified log on current macOS, so a silent
/// provider regression would leave no trace worth reading after the fact.
private let geminiTranscriberLog = Logger(
    subsystem: "com.shuiandy.Cadenza",
    category: "GeminiTranscriber"
)

/// Post-recording transcription using the Gemini API with audio input.
/// Supports chunked upload for long recordings (>10min or >15MB).
final class GeminiTranscriber: @unchecked Sendable {
    private let apiClient: GeminiTranscriptionAPIClient
    private let model: String

    /// Max concurrent API requests.
    private static let maxConcurrency = 5
    /// Max concurrent audio exports (limit I/O thrashing).
    private static let maxExportConcurrency = 3
    /// Max retry attempts per chunk.
    private static let maxRetries = 3
    /// Chunk duration in seconds (5 minutes — shorter chunks process faster with Gemini).
    private static let chunkDuration: TimeInterval = 5 * 60

    /// Progress callback reporting (chunksDone, chunksTotal) during chunked transcription.
    var onProgress: (@Sendable (Int, Int) -> Void)?

    init(
        apiKey: String,
        model: String,
        transport: HardenedAITransport = .transcription
    ) {
        self.model = model
        self.apiClient = GeminiTranscriptionAPIClient(
            apiKey: apiKey,
            model: model,
            transport: transport
        )
    }

    /// gemini-3.5-transcribe and friends speak the Interactions API and return
    /// native diarization; flash-tier models still go through the older
    /// prompt-and-JSON-schema `generateContent` path.
    private var usesInteractionsAPI: Bool {
        GeminiTranscribeInteraction.isTranscribeModel(model)
    }

    // MARK: - Public

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileNotFound
        }

        // Skip entirely silent files — prevents API hallucinations from noise/silence
        if await AudioSilenceDetector.isSilent(at: url) {
            NSLog("[GeminiTranscriber] file is silent, returning empty result")
            return TranscriptResult(text: "", segments: [], language: nil, duration: nil)
        }

        let asset = AVURLAsset(url: url)
        let totalDuration = (try? await asset.load(.duration).seconds) ?? 0
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        if let chunkingDuration = Self.chunkingDuration(
            totalDuration: totalDuration,
            fileSize: fileSize
        ) {
            return try await transcribeInChunks(
                asset: asset,
                url: url,
                totalDuration: chunkingDuration,
                language: language
            )
        }
        return try await transcribeSingleWithRetry(
            at: url,
            language: language,
            audioDuration: totalDuration > 0 ? totalDuration : nil
        )
    }

    /// Gemini's inline request limit is bounded by both playback duration and
    /// encoded bytes. Either threshold must force chunking. When AVFoundation
    /// cannot determine duration, estimate it from 128 kbps AAC so a large file
    /// never falls back to a single oversized request.
    static func chunkingDuration(totalDuration: TimeInterval, fileSize: Int) -> TimeInterval? {
        let hasValidDuration = totalDuration.isFinite && totalDuration > 0
        if hasValidDuration {
            if totalDuration > 600 || fileSize > 15_000_000 {
                return totalDuration
            }
            return nil
        }

        guard fileSize > 15_000_000 else { return nil }
        return Double(fileSize) / 16_000
    }

    // MARK: - Single File Transcription

    /// Returns the transcript plus, on the Interactions path, what the
    /// provider's response actually contained. A nil quality means the legacy
    /// generateContent path, which has no comparable signal.
    private func transcribeSingle(
        at url: URL,
        language: String?,
        audioDuration: TimeInterval?
    ) async throws -> (result: TranscriptResult, quality: GeminiTranscribeInteraction.Quality?) {
        let fileData = try Data(contentsOf: url)
        let base64Audio = fileData.base64EncodedString()
        let mimeType = mimeTypeForExtension(url.pathExtension)

        if usesInteractionsAPI {
            let requestBody = try GeminiTranscribeInteraction.makeRequestBody(
                model: model,
                base64Audio: base64Audio,
                mimeType: mimeType,
                language: language
            )
            let data = try await apiClient.createInteraction(body: requestBody)
            let parsed = try GeminiTranscribeInteraction.parse(
                data,
                language: language,
                audioDuration: audioDuration
            )
            return (parsed.result, parsed.quality)
        }

        let langInstruction = (language != nil && language != "auto") ? "Transcribe in \(language!)." : ""
        let promptText = """
            Transcribe this audio with speaker diarization. \(langInstruction)
            Rules:
            - Create a NEW segment only when the speaker changes.
            - Keep one speaker's continuous speech in a SINGLE segment, even if it is long.
            - If a single speaker talks for over 60 seconds, split at natural sentence boundaries into segments of roughly 30-60 seconds each.
            - Label speakers as "Speaker 1", "Speaker 2", etc.
            - Timestamps in seconds (approximate is fine).
            Return ONLY a valid JSON object:
            {
              "segments": [
                {"speaker": "Speaker 1", "start": 0.0, "end": 45.2, "text": "Full text of what they said."},
                {"speaker": "Speaker 2", "start": 45.5, "end": 52.0, "text": "Their response."}
              ]
            }
            """

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": promptText],
                        [
                            "inline_data": [
                                "mime_type": mimeType,
                                "data": base64Audio
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "response_mime_type": "application/json",
                "response_schema": [
                    "type": "OBJECT",
                    "properties": [
                        "segments": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "speaker": ["type": "STRING"],
                                    "start": ["type": "NUMBER"],
                                    "end": ["type": "NUMBER"],
                                    "text": ["type": "STRING"]
                                ],
                                "required": ["speaker", "start", "end", "text"]
                            ]
                        ]
                    ],
                    "required": ["segments"]
                ]
            ]
        ]

        let requestBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await apiClient.generateContent(body: requestBody)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw TranscriptionError.apiError("Failed to parse Gemini response")
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse structured JSON response (guaranteed by response_schema).
        // Fall back to plain text if parsing fails for any reason.
        if let jsonData = trimmedText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let segs = json["segments"] as? [[String: Any]] {
            let segments = segs.compactMap { seg -> TranscriptResultSegment? in
                guard let t = seg["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return TranscriptResultSegment(
                    startTime: seg["start"] as? TimeInterval ?? 0,
                    endTime: seg["end"] as? TimeInterval ?? 0,
                    text: t.trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: seg["speaker"] as? String
                )
            }
            if !segments.isEmpty {
                let fullTranscript = segments.map(\.text).joined(separator: " ")
                return (
                    TranscriptResult(text: fullTranscript, segments: segments, language: language, duration: nil),
                    nil
                )
            }
        }

        // Fallback: the model ignored the response schema. Split the text
        // rather than returning one block, for the same reason the
        // Interactions path does.
        return (
            TranscriptResult(
                text: trimmedText,
                segments: GeminiTranscribeInteraction.fallbackSegments(
                    from: trimmedText,
                    audioDuration: audioDuration
                ),
                language: language,
                duration: nil
            ),
            nil
        )
    }

    // MARK: - Retry Wrapper

    private func transcribeSingleWithRetry(
        at url: URL,
        language: String?,
        audioDuration: TimeInterval?
    ) async throws -> TranscriptResult {
        var lastError: Error?
        var lastDegraded: TranscriptResult?
        for attempt in 0..<Self.maxRetries {
            if attempt > 0 {
                let delay = Double(1 << attempt) // 2s, 4s
                geminiTranscriberLog.notice(
                    "retry \(attempt, privacy: .public) after \(delay, privacy: .public)s"
                )
                try await Task.sleep(for: .seconds(delay))
            }
            do {
                let (result, quality) = try await transcribeSingle(
                    at: url,
                    language: language,
                    audioDuration: audioDuration
                )
                // A response that dropped its word annotations is a provider
                // regression, and the one observed in August 2026 flickered
                // request to request: the same audio came back healthy on a
                // later attempt. Spend the retry budget on that before
                // accepting a chunk with interpolated timings.
                guard let quality, quality.isDegraded else { return result }
                lastDegraded = result
                if attempt < Self.maxRetries - 1 {
                    geminiTranscriberLog.notice(
                        "degraded response (\(quality.shapeDescription, privacy: .public)), retrying"
                    )
                    continue
                }
                geminiTranscriberLog.error(
                    "degraded response persisted across \(Self.maxRetries, privacy: .public) attempts (\(quality.shapeDescription, privacy: .public)); accepting interpolated segments"
                )
                return result
            } catch {
                lastError = error
                if Self.isRetryableRequestError(error), attempt < Self.maxRetries - 1 {
                    continue
                }
                throw error
            }
        }
        if let lastDegraded { return lastDegraded }
        throw lastError ?? TranscriptionError.apiError("Gemini transcription failed after retries")
    }

    static func isRetryableRequestError(_ error: Error) -> Bool {
        if case AITransportError.requestFailed = error {
            return true
        }
        if case AIServiceError.httpError(let statusCode, _) = error {
            return statusCode == 429 || (500...599).contains(statusCode)
        }
        return false
    }

    // MARK: - Chunked Transcription

    private func transcribeInChunks(
        asset: AVURLAsset,
        url: URL,
        totalDuration: TimeInterval,
        language: String?
    ) async throws -> TranscriptResult {
        guard totalDuration.isFinite, totalDuration > 0 else {
            throw TranscriptionError.apiError("Failed to split audio for chunked transcription")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cadenza-GeminiChunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Calculate chunk boundaries
        var chunks: [(index: Int, start: TimeInterval, duration: TimeInterval)] = []
        var start: TimeInterval = 0
        var index = 0
        while start < totalDuration {
            let dur = min(Self.chunkDuration, totalDuration - start)
            if dur <= 0 { break }
            chunks.append((index, start, dur))
            start += dur
            index += 1
        }

        guard !chunks.isEmpty else {
            throw TranscriptionError.apiError("Failed to split audio for chunked transcription")
        }

        NSLog("[GeminiTranscriber] splitting %.0fs audio into %d chunks (%.0fs each), concurrency=%d",
              totalDuration, chunks.count, Self.chunkDuration, Self.maxConcurrency)

        // Two permit pools: export bounds I/O, API bounds network calls.
        // This enables pipelining: chunk N uploads while chunk N+1 exports.
        let exportPermits = AsyncPermitPool(limit: Self.maxExportConcurrency)
        let apiPermits = AsyncPermitPool(limit: Self.maxConcurrency)

        let chunkResults = try await withThrowingTaskGroup(
            of: (Int, TimeInterval, TimeInterval, TranscriptResult).self
        ) { group in
            for chunk in chunks {
                group.addTask {
                    // Phase 1: Export (bounded by I/O concurrency)
                    let outputURL = tempDir.appendingPathComponent("chunk-\(chunk.index).m4a")
                    try await exportPermits.withPermit {
                        try await self.exportChunk(
                            asset: asset,
                            start: chunk.start,
                            duration: chunk.duration,
                            outputURL: outputURL
                        )
                    }
                    defer { try? FileManager.default.removeItem(at: outputURL) }

                    // Skip silent chunks to avoid API hallucinations and save cost
                    if await AudioSilenceDetector.isSilent(at: outputURL) {
                        return (chunk.index, chunk.start, chunk.duration, TranscriptResult(text: "", segments: [], language: nil, duration: chunk.duration))
                    }

                    // Phase 2: API call (bounded by network concurrency)
                    let result = try await apiPermits.withPermit {
                        try await self.transcribeSingleWithRetry(
                            at: outputURL,
                            language: language,
                            audioDuration: chunk.duration
                        )
                    }
                    return (chunk.index, chunk.start, chunk.duration, result)
                }
            }
            var results: [(Int, TimeInterval, TimeInterval, TranscriptResult)] = []
            for try await item in group {
                results.append(item)
                self.onProgress?(results.count, chunks.count)
            }
            return results
        }

        // Sort by original order and merge
        let sorted = chunkResults.sorted { $0.0 < $1.0 }
        var mergedText: [String] = []
        var mergedSegments: [TranscriptResultSegment] = []

        for (_, startOffset, dur, result) in sorted {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { mergedText.append(text) }

            if result.segments.isEmpty {
                if !text.isEmpty {
                    mergedSegments.append(TranscriptResultSegment(
                        startTime: startOffset, endTime: startOffset + dur, text: text
                    ))
                }
            } else {
                for seg in result.segments {
                    let segStart = max(0, seg.startTime + startOffset)
                    let segEnd = max(segStart, seg.endTime + startOffset)
                    mergedSegments.append(TranscriptResultSegment(
                        startTime: segStart,
                        endTime: segEnd,
                        text: seg.text,
                        // spk_1 in chunk 0 and spk_1 in chunk 1 are unrelated
                        // request-local labels. Keeping them would invent a
                        // recording-wide identity out of nothing, so split
                        // audio defers to the later local diarization pass —
                        // the same rule WhisperTranscriber applies.
                        speaker: WhisperTranscriber.speakerLabelForMergedChunks(
                            seg.speaker,
                            totalChunkCount: chunks.count
                        )
                    ))
                }
            }
        }

        // Sort segments by time — Gemini may return inconsistent timestamps across chunks
        mergedSegments.sort { $0.startTime < $1.startTime }

        return TranscriptResult(
            text: mergedText.joined(separator: " "),
            segments: mergedSegments,
            language: language,
            duration: totalDuration
        )
    }

    // MARK: - Audio Chunk Export

    /// Export a time range of audio, compressed to mono 16kHz AAC 32kbps for minimal upload size.
    /// Speech recognition models internally downsample to 16kHz mono, so this is lossless
    /// from a transcription quality perspective while reducing file size by ~4-5x.
    private func exportChunk(
        asset: AVURLAsset,
        start: TimeInterval,
        duration: TimeInterval,
        outputURL: URL
    ) async throws {
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        nonisolated(unsafe) let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.apiError("No audio track found")
        }

        // Decode to PCM mono 16kHz for re-encoding
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        nonisolated(unsafe) let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        guard reader.canAdd(readerOutput) else {
            throw TranscriptionError.apiError("Cannot add reader output")
        }
        reader.add(readerOutput)

        // Encode to AAC mono 16kHz 32kbps (sufficient for speech)
        nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        nonisolated(unsafe) let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerInputSettings)
        guard writer.canAdd(writerInput) else {
            throw TranscriptionError.apiError("Cannot add writer input")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError.apiError("Audio reader failed to start")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? TranscriptionError.apiError("Audio writer failed to start")
        }
        writer.startSession(atSourceTime: timeRange.start)

        let exportDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        let pumpTerminalAction = OSAllocatedUnfairLock(initialState: false)
        try await CancellableCallbackOperation.run(for: .seconds(30)) { complete, isActive in
            let queue = DispatchQueue(label: "cadenza.gemini-chunk-export", qos: .utility)
            writerInput.requestMediaDataWhenReady(on: queue) {
                guard isActive() else { return }
                while writerInput.isReadyForMoreMediaData, isActive() {
                    if reader.status == .failed {
                        _ = complete(.failure(
                            reader.error ?? TranscriptionError.apiError("Audio read failed")
                        ))
                        return
                    }
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            _ = complete(.failure(TranscriptionError.apiError(
                                "Chunk export: writer rejected sample buffer"
                            )))
                            return
                        }
                    } else {
                        guard reader.status == .completed else {
                            if reader.status == .cancelled {
                                _ = complete(.failure(CancellationError()))
                            }
                            return
                        }
                        let didMarkFinished = pumpTerminalAction.withLock { state in
                            guard !state else { return false }
                            state = true
                            writerInput.markAsFinished()
                            return true
                        }
                        guard didMarkFinished else { return }
                        _ = complete(.success(()))
                        return
                    }
                }
            }
        } cancel: {
            pumpTerminalAction.withLock { $0 = true }
            reader.cancelReading()
            writer.cancelWriting()
        }

        let remaining = ContinuousClock.now.duration(to: exportDeadline)
        guard remaining > .zero else {
            reader.cancelReading()
            writer.cancelWriting()
            throw AsyncCallbackTimeoutError()
        }

        try await CancellableCallbackOperation.run(for: remaining) { complete, _ in
            writer.finishWriting {
                _ = complete(.success(()))
            }
        } cancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }

        guard writer.status == .completed else {
            throw writer.error ?? TranscriptionError.apiError("Chunk export failed")
        }
    }

    // MARK: - Helpers

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "webm": "audio/webm"
        case "ogg": "audio/ogg"
        case "flac": "audio/flac"
        default: "audio/mp4"
        }
    }
}
