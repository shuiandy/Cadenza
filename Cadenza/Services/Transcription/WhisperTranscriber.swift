import Foundation
@preconcurrency import AVFoundation
import os

/// Post-recording transcription using OpenAI Audio API.
/// Supports chunked uploads for oversized files and long diarized recordings.
/// Default model is gpt-4o-transcribe. Also supports gpt-4o-mini-transcribe and whisper-1.
final class WhisperTranscriber: TranscriptionService, Sendable {
    private let model: String
    private let apiClient: any OpenAITranscriptionRequesting
    private let retrySleep: @Sendable (Duration) async throws -> Void
    static let openAIMaxUploadBytes = 25 * 1024 * 1024
    /// The diarization endpoint rejects audio longer than 1,400 seconds even
    /// when the encoded file is below the upload-size limit.
    static let diarizeMaxSingleRequestDuration: TimeInterval = 1_400
    /// Diarized requests above this duration are proactively split. In practice,
    /// long uploads can time out before reaching the endpoint's hard limits.
    static let diarizeChunkTriggerThreshold: TimeInterval = 10 * 60
    /// Chunk size when a diarized upload exceeds the proactive threshold or a
    /// hard API limit.
    /// Labels from these requests are reconciled against a recording-wide local
    /// diarization pass before consecutive transcript entries are merged.
    static let diarizeChunkDuration: TimeInterval = 5 * 60
    static let standardChunkDuration: TimeInterval = 20 * 60
    /// Max concurrent API requests (avoid 429 rate limiting).
    private static let maxConcurrency = 6
    /// Max concurrent audio exports. Matched to maxConcurrency so chunk exports
    /// keep all upload slots fed instead of bottlenecking the pipeline at 3.
    private static let maxExportConcurrency = 6
    /// Max retry attempts per chunk.
    private static let maxRetries = 3

    /// Progress callback reporting (chunksDone, chunksTotal) during chunked transcription.
    private let onProgress: (@Sendable (Int, Int) -> Void)?

    init(
        apiKey: String,
        model: String,
        transport: HardenedAITransport = .transcription,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.model = model
        self.apiClient = OpenAITranscriptionAPIClient(
            apiKey: apiKey,
            transport: transport
        )
        self.onProgress = onProgress
        self.retrySleep = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        model: String,
        apiClient: any OpenAITranscriptionRequesting,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.model = model
        self.apiClient = apiClient
        self.onProgress = onProgress
        self.retrySleep = retrySleep
    }

    // MARK: - File Transcription

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileNotFound
        }

        // Skip entirely silent files — prevents API hallucinations from noise/silence
        if await AudioSilenceDetector.isSilent(at: url) {
            NSLog("[WhisperTranscriber] file is silent, returning empty result")
            return TranscriptResult(text: "", segments: [], language: nil, duration: nil)
        }

        let maxSize = Self.openAIMaxUploadBytes
        let fileSize = try fileSizeBytes(for: url)

        // Check audio duration against model limit.
        let asset = AVURLAsset(url: url)
        let audioDuration = (try? await asset.load(.duration).seconds) ?? 0

        if let chunkDuration = Self.chunkDurationForUpload(
            model: model,
            fileSize: fileSize,
            audioDuration: audioDuration,
            maxUploadBytes: maxSize
        ) {
            return try await transcribeLargeFileInChunks(
                at: url, language: language, maxUploadBytes: maxSize, chunkDuration: chunkDuration
            )
        } else {
            return try await transcribeSingleFile(at: url, language: language)
        }
    }

    static func chunkDurationForUpload(
        model: String,
        fileSize: Int,
        audioDuration: TimeInterval,
        maxUploadBytes: Int = openAIMaxUploadBytes
    ) -> TimeInterval? {
        let isDiarize = model.localizedCaseInsensitiveContains("diarize")
        if isDiarize {
            let hasKnownDuration = audioDuration.isFinite && audioDuration > 0
            let exceedsProactiveThreshold = hasKnownDuration
                && audioDuration > Self.diarizeChunkTriggerThreshold
            if fileSize > maxUploadBytes || exceedsProactiveThreshold {
                return diarizeChunkDuration
            }
            return nil
        }

        if fileSize > maxUploadBytes {
            return standardChunkDuration
        }
        return nil
    }

    private func transcribeSingleFile(
        at url: URL,
        language: String?,
        apiPermits: AsyncPermitPool? = nil
    ) async throws -> TranscriptResult {
        if let apiPermits {
            return try await uploadWithRetry(apiPermits: apiPermits) {
                let fileData = try Data(contentsOf: url)
                return self.buildMultipartBody(
                    fileData: fileData,
                    filename: url.lastPathComponent,
                    ext: url.pathExtension,
                    language: language
                )
            }
        }

        let fileData = try Data(contentsOf: url)
        let body = buildMultipartBody(fileData: fileData, filename: url.lastPathComponent, ext: url.pathExtension, language: language)
        return try await uploadWithRetry(body: body)
    }

    /// Build multipart/form-data body for the transcription API.
    private func buildMultipartBody(fileData: Data, filename: String, ext: String, language: String?) -> WhisperMultipartBody {
        let boundary = UUID().uuidString
        var body = Data()

        body.appendMultipart(name: "model", value: model, boundary: boundary)

        if let language, language != "auto" {
            body.appendMultipart(name: "language", value: language, boundary: boundary)
        }

        if model.contains("diarize") {
            body.appendMultipart(name: "response_format", value: "diarized_json", boundary: boundary)
            body.appendMultipart(name: "chunking_strategy", value: "auto", boundary: boundary)
        } else {
            // verbose_json gives us timestamped segments for all models (whisper-1, gpt-4o-transcribe, etc.)
            body.appendMultipart(name: "response_format", value: "verbose_json", boundary: boundary)
            body.appendMultipart(name: "timestamp_granularities[]", value: "segment", boundary: boundary)
        }

        let mimeType = mimeTypeForExtension(ext)
        body.appendMultipartFile(name: "file", filename: filename, mimeType: mimeType, data: fileData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return WhisperMultipartBody(boundary: boundary, data: body)
    }

    /// Upload with per-request retry and exponential backoff.
    func uploadWithRetry(
        body: WhisperMultipartBody,
        apiPermits: AsyncPermitPool? = nil
    ) async throws -> TranscriptResult {
        try await uploadWithRetry(apiPermits: apiPermits) { body }
    }

    func uploadWithRetry(
        apiPermits: AsyncPermitPool? = nil,
        bodyProvider: @escaping @Sendable () throws -> WhisperMultipartBody
    ) async throws -> TranscriptResult {
        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            if attempt > 0 {
                let delay = Double(1 << attempt) // 2s, 4s
                NSLog("[WhisperTranscriber] retry attempt %d after %.0fs", attempt, delay)
                try await retrySleep(.seconds(delay))
            }
            do {
                let requestAttempt: @Sendable () async throws -> Data = {
                    let body = try bodyProvider()
                    return try await self.apiClient.transcribe(
                        multipartBody: body.data,
                        boundary: body.boundary
                    )
                }
                let data: Data
                if let apiPermits {
                    data = try await apiPermits.withPermit(requestAttempt)
                } else {
                    data = try await requestAttempt()
                }
                return try parseResponse(data)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                if Self.isRetryableRequestError(error), attempt < Self.maxRetries - 1 {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? TranscriptionError.apiError("Transcription failed after retries")
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

    private func transcribeLargeFileInChunks(
        at url: URL,
        language: String?,
        maxUploadBytes: Int,
        chunkDuration: TimeInterval = 12 * 60
    ) async throws -> TranscriptResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cadenza-WhisperChunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let asset = AVURLAsset(url: url)
        let totalDuration = try await asset.load(.duration).seconds
        guard totalDuration.isFinite, totalDuration > 0 else {
            throw TranscriptionError.apiError("Failed to split large audio for transcription")
        }

        // Calculate chunk boundaries
        var chunkInfos: [(index: Int, start: TimeInterval, duration: TimeInterval)] = []
        var start: TimeInterval = 0
        var index = 0
        while start < totalDuration {
            let end = min(totalDuration, start + chunkDuration)
            let dur = max(0, end - start)
            if dur <= 0 { break }
            chunkInfos.append((index, start, dur))
            start = end
            index += 1
        }
        guard !chunkInfos.isEmpty else {
            throw TranscriptionError.apiError("Failed to split large audio for transcription")
        }

        onProgress?(0, chunkInfos.count)
        NSLog("[WhisperTranscriber] splitting %.0fs audio into %d chunks (%.0fs each), concurrency=%d",
              totalDuration, chunkInfos.count, chunkDuration, Self.maxConcurrency)

        // Two permit pools: export bounds I/O, API bounds network calls.
        // This enables pipelining: chunk N uploads while chunk N+1 exports.
        let exportPermits = AsyncPermitPool(limit: Self.maxExportConcurrency)
        let apiPermits = AsyncPermitPool(limit: Self.maxConcurrency)

        // Pipeline: export + transcribe each chunk with bounded concurrency
        let chunkResults: [(index: Int, startOffset: TimeInterval, duration: TimeInterval, result: TranscriptResult)]
        chunkResults = try await withThrowingTaskGroup(
            of: (Int, TimeInterval, TimeInterval, TranscriptResult).self
        ) { group in
            for info in chunkInfos {
                group.addTask {
                    // Phase 1: Export (bounded by I/O concurrency)
                    let outputURL = tempDir.appendingPathComponent("chunk-\(info.index).m4a")
                    try await exportPermits.withPermit {
                        try await self.exportChunk(
                            asset: asset,
                            start: info.start,
                            duration: info.duration,
                            outputURL: outputURL
                        )
                    }
                    defer { try? FileManager.default.removeItem(at: outputURL) }

                    // Validate size
                    let bytes = try self.fileSizeBytes(for: outputURL)
                    if bytes > maxUploadBytes {
                        throw TranscriptionError.fileTooLarge
                    }

                    // Skip silent chunks to avoid API hallucinations and save cost
                    if await AudioSilenceDetector.isSilent(at: outputURL) {
                        return (info.index, info.start, info.duration, TranscriptResult(text: "", segments: [], language: nil, duration: info.duration))
                    }

                    // Phase 2: Each network attempt is bounded independently.
                    // Retried chunks release their permit during 2s/4s backoff,
                    // allowing other ready chunks to use the upload slots.
                    let result = try await self.transcribeSingleFile(
                        at: outputURL,
                        language: language,
                        apiPermits: apiPermits
                    )
                    return (info.index, info.start, info.duration, result)
                }
            }
            var results: [(Int, TimeInterval, TimeInterval, TranscriptResult)] = []
            var progressReporter = WhisperChunkProgressReporter(
                total: chunkInfos.count,
                onProgress: self.onProgress
            )
            for try await item in group {
                results.append(item)
                progressReporter.reportCompletion()
            }
            return results
        }

        // Sort by original order and merge
        let sorted = chunkResults.sorted { $0.0 < $1.0 }
        var mergedTextParts: [String] = []
        var mergedSegments: [TranscriptResultSegment] = []
        var mergedLanguage: String?

        for (_, startOffset, dur, result) in sorted {
            let cleanedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedText.isEmpty {
                mergedTextParts.append(cleanedText)
            }
            if mergedLanguage == nil {
                mergedLanguage = result.language
            }

            if result.segments.isEmpty {
                if !cleanedText.isEmpty {
                    let end = startOffset + dur
                    mergedSegments.append(
                        TranscriptResultSegment(startTime: startOffset, endTime: end, text: cleanedText)
                    )
                }
            } else {
                for seg in result.segments {
                    let segStart = max(0, seg.startTime + startOffset)
                    let segEnd = max(segStart, seg.endTime + startOffset)
                    mergedSegments.append(TranscriptResultSegment(
                        startTime: segStart,
                        endTime: segEnd,
                        text: seg.text,
                        speaker: Self.speakerLabelForMergedChunks(
                            seg.speaker,
                            totalChunkCount: chunkInfos.count
                        )
                    ))
                }
            }
        }

        let mergedText = mergedTextParts.joined(separator: " ")
        let duration = chunkInfos.last.map { $0.start + $0.duration }
        return TranscriptResult(
            text: mergedText,
            segments: mergedSegments,
            language: mergedLanguage,
            duration: duration
        )
    }

    /// Export a time range of audio, compressed to mono 16kHz AAC for minimal upload size.
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
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
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
            let queue = DispatchQueue(label: "cadenza.audio-compress")
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
            throw writer.error ?? TranscriptionError.apiError("Audio compression failed")
        }
    }

    private func fileSizeBytes(for url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    // MARK: - Parse Response

    private func parseResponse(_ data: Data) throws -> TranscriptResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.apiError("Invalid JSON response")
        }

        let text = json["text"] as? String ?? ""
        let language = json["language"] as? String
        let duration = json["duration"] as? TimeInterval

        // Log top-level keys to diagnose response structure
        NSLog("[WhisperTranscriber] response keys: %@", json.keys.sorted().joined(separator: ", "))

        var segments: [TranscriptResultSegment] = []

        // Diarize models return "chunks" with speaker info instead of "segments"
        if let chunks = json["chunks"] as? [[String: Any]] {
            NSLog("[WhisperTranscriber] found %d chunks, first chunk keys: %@",
                  chunks.count, chunks.first?.keys.sorted().joined(separator: ", ") ?? "none")
            for chunk in chunks {
                let chunkText = chunk["text"] as? String ?? ""
                let speaker = Self.normalizedSpeakerLabel(chunk["speaker"] as? String)
                var start: TimeInterval = 0
                var end: TimeInterval = 0
                if let timestamp = chunk["timestamp"] as? [Double], timestamp.count >= 2 {
                    start = timestamp[0]
                    end = timestamp[1]
                }
                segments.append(TranscriptResultSegment(startTime: start, endTime: end, text: chunkText, speaker: speaker))
            }
        } else if let jsonSegments = json["segments"] as? [[String: Any]] {
            for seg in jsonSegments {
                let start = seg["start"] as? TimeInterval ?? 0
                let end = seg["end"] as? TimeInterval ?? 0
                let segText = seg["text"] as? String ?? ""
                let speaker = Self.normalizedSpeakerLabel(seg["speaker"] as? String)
                segments.append(TranscriptResultSegment(startTime: start, endTime: end, text: segText, speaker: speaker))
            }
        }

        let merged = Self.mergeSameSpeakerSegments(segments)
        return TranscriptResult(text: text, segments: merged, language: language, duration: duration)
    }

    static func normalizedSpeakerLabel(_ rawLabel: String?) -> String? {
        guard let rawLabel else { return nil }
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return nil
        }
        return trimmed
    }

    /// A/B labels are only stable within one diarization request. When audio had
    /// to be split, retaining them would turn unrelated request-local labels into
    /// recording-wide identities. A later local pass may safely fill them back in.
    static func speakerLabelForMergedChunks(
        _ rawLabel: String?,
        totalChunkCount: Int
    ) -> String? {
        totalChunkCount <= 1 ? rawLabel : nil
    }

    /// Merge consecutive segments from the same speaker into one.
    private static func mergeSameSpeakerSegments(_ segments: [TranscriptResultSegment]) -> [TranscriptResultSegment] {
        guard !segments.isEmpty else { return [] }
        var result: [TranscriptResultSegment] = []
        var startTime = segments[0].startTime
        var endTime = segments[0].endTime
        var speaker = segments[0].speaker
        var parts: [String] = [segments[0].text.trimmingCharacters(in: .whitespaces)]

        for seg in segments.dropFirst() {
            if seg.speaker == speaker {
                endTime = seg.endTime
                parts.append(seg.text.trimmingCharacters(in: .whitespaces))
            } else {
                result.append(TranscriptResultSegment(startTime: startTime, endTime: endTime, text: parts.joined(separator: " "), speaker: speaker))
                startTime = seg.startTime
                endTime = seg.endTime
                speaker = seg.speaker
                parts = [seg.text.trimmingCharacters(in: .whitespaces)]
            }
        }
        result.append(TranscriptResultSegment(startTime: startTime, endTime: endTime, text: parts.joined(separator: " "), speaker: speaker))
        return result
    }

    // MARK: - Realtime (not supported)

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        throw TranscriptionError.notSupported("Use RealtimeTranscriber for real-time transcription")
    }

    func sendAudio(_ data: Data) async throws {
        throw TranscriptionError.notSupported("Use RealtimeTranscriber for real-time transcription")
    }

    func stopRealtimeSession() async throws {}

    // MARK: - Helpers

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m4a": "audio/m4a"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "webm": "audio/webm"
        case "ogg": "audio/ogg"
        case "flac": "audio/flac"
        default: "audio/m4a"
        }
    }
}

struct WhisperChunkProgressReporter: Sendable {
    private let total: Int
    private let onProgress: (@Sendable (Int, Int) -> Void)?
    private var completed = 0

    init(
        total: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) {
        self.total = total
        self.onProgress = onProgress
    }

    mutating func reportCompletion() {
        completed += 1
        onProgress?(completed, total)
    }
}

struct WhisperMultipartBody: Sendable {
    let boundary: String
    let data: Data
}

// MARK: - Multipart Helpers

private extension Data {
    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
