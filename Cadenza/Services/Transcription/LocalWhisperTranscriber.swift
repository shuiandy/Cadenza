@preconcurrency import AVFoundation
import Foundation
import WhisperKit

/// On-device transcription using WhisperKit (CoreML).
final class LocalWhisperTranscriber: TranscriptionService, Sendable {
    private static let runtime = LocalWhisperPipelineRuntime()

    private let modelName: String
    private let onProgress: (@Sendable (Int, Int) -> Void)?

    init(
        modelName: String = "base",
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.modelName = modelName
        self.onProgress = onProgress
    }

    // MARK: - File Transcription

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        do {
            return try await transcribeFileImplementation(at: url, language: language)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[LocalWhisper] transcription failed: %@", String(describing: error))
            throw TranscriptionError.userVisible(from: error)
        }
    }

    private func transcribeFileImplementation(
        at url: URL,
        language: String?
    ) async throws -> TranscriptResult {
        let modelFolder = await WhisperModelManager.shared.modelPath(for: modelName)
        guard let modelFolder else {
            throw TranscriptionError.apiError("Whisper model '\(modelName)' is not downloaded. Please download it in Settings → Transcription.")
        }

        let audioURL = try await ensureLocalFile(url)

        // Convert to 16kHz mono WAV — WhisperKit can fail on certain audio formats.
        let wavURL = try await convertToWhisperFormat(audioURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let audioDuration = try Self.audioDuration(at: wavURL)

        var options = DecodingOptions()
        options.language = language
        options.wordTimestamps = false

        let runtimeResult = try await Self.runtime.transcribe(
            modelName: modelName,
            modelFolder: modelFolder,
            audioURL: wavURL,
            duration: audioDuration,
            options: options,
            onProgress: onProgress
        )
        return Self.makeTranscriptResult(
            from: runtimeResult,
            requestedLanguage: language,
            audioDuration: audioDuration
        )
    }

    static func makeTranscriptResult(
        from runtimeResult: LocalWhisperRuntimeResult,
        requestedLanguage: String?,
        audioDuration: TimeInterval
    ) -> TranscriptResult {
        let cleanedRawSegments = runtimeResult.segments.compactMap {
            segment -> TranscriptionSegment? in
            let cleanedText = cleanWhisperText(segment.text)
            guard !cleanedText.isEmpty else { return nil }
            var cleanedSegment = segment
            cleanedSegment.text = cleanedText
            return cleanedSegment
        }
        let segments = cleanedRawSegments.map {
            TranscriptResultSegment(
                startTime: TimeInterval($0.start),
                endTime: TimeInterval($0.end),
                text: $0.text
            )
        }
        let fullText = segments.map(\.text).joined(separator: " ")
        let language = runtimeResult.language.flatMap { $0.isEmpty ? nil : $0 }
            ?? requestedLanguage

        let whisperResults: [TranscriptionResult]? = if cleanedRawSegments.isEmpty {
            nil
        } else {
            [
                TranscriptionResult(
                    text: fullText,
                    segments: cleanedRawSegments,
                    language: language ?? "",
                    timings: runtimeResult.timings ?? TranscriptionTimings(),
                    seekTime: 0
                )
            ]
        }

        return TranscriptResult(
            text: fullText,
            segments: segments,
            language: language,
            duration: audioDuration,
            whisperResults: whisperResults
        )
    }

    // MARK: - iCloud Download

    private func ensureLocalFile(_ url: URL) async throws -> URL {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: url.path) { return url }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TranscriptionError.fileNotFound
    }

    // MARK: - Real-time (Not Supported)

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        throw TranscriptionError.notSupported("Local Whisper does not support real-time transcription")
    }

    func sendAudio(_ data: Data) async throws {
        throw TranscriptionError.notSupported("Local Whisper does not support real-time transcription")
    }

    func stopRealtimeSession() async throws {
        throw TranscriptionError.notSupported("Local Whisper does not support real-time transcription")
    }

    // MARK: - Text Cleaning

    private static func cleanWhisperText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Audio Conversion

    private static let convertQueue = DispatchQueue(label: "com.shuiandy.Cadenza.whisper-convert", qos: .utility)

    private static func audioDuration(at url: URL) throws -> TimeInterval {
        let audioFile = try AVAudioFile(forReading: url)
        let sampleRate = audioFile.fileFormat.sampleRate
        guard sampleRate > 0 else {
            throw TranscriptionError.apiError("Converted audio has an invalid sample rate")
        }
        return TimeInterval(audioFile.length) / sampleRate
    }

    private func convertToWhisperFormat(_ inputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let reader = try AVAssetReader(asset: asset)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.apiError("No audio track found in file")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        nonisolated(unsafe) let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        nonisolated(unsafe) let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: Self.convertQueue) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(buffer)
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw TranscriptionError.apiError("Audio conversion failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        return outputURL
    }

    // MARK: - Pipeline Management

    static func releasePipeline() async throws {
        try await runtime.releasePipeline()
    }

    static func deleteModel(named modelName: String) async throws {
        try await runtime.withReleasedPipeline {
            try await MainActor.run {
                try WhisperModelManager.shared.delete(model: modelName)
            }
        }
    }
}
