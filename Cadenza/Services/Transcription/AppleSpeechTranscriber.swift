import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
import CoreMedia

enum AppleSpeechFactory {
    static var isSupportedOnCurrentOS: Bool {
        if #available(macOS 26.0, *) {
            true
        } else {
            false
        }
    }

    static func supportsLanguage(_ language: String?) async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return await AppleSpeechTranscriber.supportsLanguage(language)
    }

    static func makeTranscriber(language: String?) -> (any TranscriptionService)? {
        guard #available(macOS 26.0, *) else { return nil }
        return AppleSpeechTranscriber(language: language)
    }
}

/// On-device transcription using Apple's SpeechAnalyzer + SpeechTranscriber APIs (macOS 26+).
/// Supports both file-based and real-time streaming transcription with no network dependency.
@available(macOS 26.0, *)
final class AppleSpeechTranscriber: TranscriptionService, @unchecked Sendable {
    private let locale: Locale

    /// Actor-isolated mutable state for the active realtime session.
    private let sessionState = SessionState()

    /// 24kHz mono PCM16 — matches AudioConverter.transcriptionFormat used by AudioMixer.
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true
    )!

    // MARK: - Session State Actor

    private actor SessionState {
        var analyzer: SpeechAnalyzer?
        var transcriber: SpeechTranscriber?
        var converter: AVAudioConverter?
        var targetFormat: AVAudioFormat?
        var outputContinuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
        var iterationTask: Task<Void, Never>?
        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

        /// Store audio pipeline components — call BEFORE creating output stream.
        func storeAudioPipeline(
            analyzer: SpeechAnalyzer,
            transcriber: SpeechTranscriber,
            converter: AVAudioConverter?,
            targetFormat: AVAudioFormat,
            inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        ) {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.converter = converter
            self.targetFormat = targetFormat
            self.inputContinuation = inputContinuation
        }

        func storeOutputContinuation(_ continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation) {
            self.outputContinuation = continuation
        }

        func setIterationTask(_ task: Task<Void, Never>) {
            self.iterationTask = task
        }

        func getAudioPipeline() -> (converter: AVAudioConverter?, targetFormat: AVAudioFormat?, inputContinuation: AsyncStream<AnalyzerInput>.Continuation?) {
            (converter, targetFormat, inputContinuation)
        }

        func yieldDelta(_ delta: TranscriptDelta) {
            outputContinuation?.yield(delta)
        }

        func finishStream() {
            outputContinuation?.finish()
            outputContinuation = nil
        }

        func finishStream(throwing error: Error) {
            outputContinuation?.finish(throwing: error)
            outputContinuation = nil
        }

        func stopSnapshot() -> (analyzer: SpeechAnalyzer?, iterationTask: Task<Void, Never>?, inputContinuation: AsyncStream<AnalyzerInput>.Continuation?) {
            (analyzer, iterationTask, inputContinuation)
        }

        func clearStopResources() {
            analyzer = nil
            transcriber = nil
            converter = nil
            targetFormat = nil
            iterationTask = nil
            inputContinuation = nil
        }

        func teardown() -> (analyzer: SpeechAnalyzer?, iterationTask: Task<Void, Never>?, outputContinuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?, inputContinuation: AsyncStream<AnalyzerInput>.Continuation?) {
            let result = (analyzer, iterationTask, outputContinuation, inputContinuation)
            analyzer = nil
            transcriber = nil
            converter = nil
            targetFormat = nil
            outputContinuation = nil
            iterationTask = nil
            inputContinuation = nil
            return result
        }
    }

    // MARK: - Init

    init(language: String? = nil) {
        if let language, !language.isEmpty, language != "auto" {
            self.locale = Locale(identifier: language)
        } else {
            self.locale = .current
        }
    }

    // MARK: - Language Support

    static func supportsLanguage(_ language: String?) async -> Bool {
        let locales = await SpeechTranscriber.supportedLocales
        guard let language, !language.isEmpty, language != "auto" else {
            // Check if current locale is supported
            let current = Locale.current
            return locales.contains { $0.language.languageCode == current.language.languageCode }
        }
        let target = Locale(identifier: language)
        return locales.contains { $0.language.languageCode == target.language.languageCode }
    }

    // MARK: - Resolve Locale

    /// Resolve the configured locale to a supported locale, falling back to the system locale.
    private func resolveLocale() async -> Locale {
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return supported
        }
        // Fall back to current locale
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return supported
        }
        // Last resort: English
        return Locale(identifier: "en-US")
    }

    /// Resolve a language string to a supported locale.
    private func resolveLanguage(_ language: String?) async -> Locale {
        if let language, !language.isEmpty, language != "auto" {
            let requestedLocale = Locale(identifier: language)
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
                return supported
            }
        }
        return await resolveLocale()
    }

    // MARK: - File Transcription

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        do {
            return try await transcribeFileImplementation(at: url, language: language)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[AppleSpeech] file transcription failed: %@", String(describing: error))
            throw TranscriptionError.userVisible(from: error)
        }
    }

    private func transcribeFileImplementation(
        at url: URL,
        language: String?
    ) async throws -> TranscriptResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.fileNotFound
        }

        let resolvedLocale = await resolveLanguage(language)

        // Create transcriber with time-indexed results for file analysis
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Try original file first; fall back to format conversion if incompatible.
        let analyzerOptions = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
        )

        var audioFile: AVAudioFile
        var convertedURL: URL?

        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.apiError("Cannot open audio file: \(error.localizedDescription)")
        }

        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                options: analyzerOptions,
                finishAfterFile: true
            )
            NSLog("[AppleSpeech] using original file format: %.0fHz %dch", audioFile.fileFormat.sampleRate, audioFile.fileFormat.channelCount)
        } catch {
            // Format incompatible — convert to 16kHz mono PCM WAV and retry
            NSLog("[AppleSpeech] original format failed (%@), converting to 16kHz mono", error.localizedDescription)
            let tempURL = try await Self.convertToSpeechFormat(url)
            convertedURL = tempURL
            audioFile = try AVAudioFile(forReading: tempURL)
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                options: analyzerOptions,
                finishAfterFile: true
            )
        }
        defer { if let u = convertedURL { try? FileManager.default.removeItem(at: u) } }

        let fileDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        NSLog("[AppleSpeech] file duration: %.1fs, starting transcription", fileDuration)

        // Collect results
        var segments: [TranscriptResultSegment] = []
        var allText: [String] = []
        var detectedLanguage: String? = nil
        var totalResults = 0
        var finalResults = 0

        for try await result in transcriber.results {
            totalResults += 1
            guard result.isFinal else { continue }
            finalResults += 1

            let attributedText = result.text
            let plainText = String(attributedText.characters)
            let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            allText.append(trimmed)

            // Extract time range from the result's range (CMTimeRange)
            let startSeconds = CMTimeGetSeconds(result.range.start)
            let endSeconds = CMTimeGetSeconds(result.range.end)
            let segStart = startSeconds.isFinite ? max(0, startSeconds) : 0
            let segEnd = endSeconds.isFinite ? max(segStart, endSeconds) : segStart

            // Try to extract per-run time ranges from attributed string attributes
            var runs: [(text: String, start: TimeInterval, end: TimeInterval)] = []
            for run in attributedText.runs {
                let runText = String(attributedText[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !runText.isEmpty else { continue }

                if let timeRange = run.audioTimeRange {
                    let rStart = CMTimeGetSeconds(timeRange.start)
                    let rEnd = CMTimeGetSeconds(timeRange.end)
                    let s = rStart.isFinite ? max(0, rStart) : segStart
                    let e = rEnd.isFinite ? max(s, rEnd) : segEnd
                    runs.append((runText, s, e))
                } else {
                    runs.append((runText, segStart, segEnd))
                }
            }

            if runs.isEmpty {
                segments.append(TranscriptResultSegment(
                    startTime: segStart,
                    endTime: segEnd,
                    text: trimmed
                ))
            } else {
                // Merge runs into a single segment per result for cleaner output
                let mergedText = runs.map(\.text).joined(separator: " ")
                let mergedStart = runs.map(\.start).min() ?? segStart
                let mergedEnd = runs.map(\.end).max() ?? segEnd
                segments.append(TranscriptResultSegment(
                    startTime: mergedStart,
                    endTime: mergedEnd,
                    text: mergedText
                ))
            }

            if detectedLanguage == nil {
                detectedLanguage = resolvedLocale.language.languageCode?.identifier
            }
        }

        _ = analyzer // keep analyzer alive during result iteration
        let fullText = allText.joined(separator: " ")
        NSLog("[AppleSpeech] file transcription done: %d total results, %d final, %d segments, %d chars",
              totalResults, finalResults, segments.count, fullText.count)

        return TranscriptResult(
            text: fullText,
            segments: segments,
            language: detectedLanguage,
            duration: fileDuration
        )
    }

    // MARK: - Real-time Transcription

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        do {
            return try await startRealtimeSessionImplementation(language: language)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[AppleSpeech] realtime setup failed: %@", String(describing: error))
            throw TranscriptionError.userVisible(from: error)
        }
    }

    private func startRealtimeSessionImplementation(
        language: String?
    ) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        NSLog("[AppleSpeech] startRealtimeSession: language=%@", language ?? "nil")
        let resolvedLocale = await resolveLanguage(language)
        NSLog("[AppleSpeech] resolved locale: %@", resolvedLocale.identifier)

        // Create transcriber with volatile results for real-time feedback
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // Get the best audio format for the transcriber
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: Self.inputFormat
        ) ?? Self.inputFormat

        // Set up audio converter if formats differ
        let converter: AVAudioConverter?
        if targetFormat.sampleRate != Self.inputFormat.sampleRate
            || targetFormat.channelCount != Self.inputFormat.channelCount
            || targetFormat.commonFormat != Self.inputFormat.commonFormat {
            guard let c = AVAudioConverter(from: Self.inputFormat, to: targetFormat) else {
                throw TranscriptionError.apiError("Failed to create audio format converter for Apple speech recognition")
            }
            converter = c
        } else {
            converter = nil
        }

        // Create an AsyncStream to feed audio buffers into the analyzer.
        // Use bounded buffer (64 items ≈ ~10s of audio) to prevent OOM when analyzer falls behind.
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))

        // Create analyzer with input sequence — retain model for process lifetime
        let options = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
        )
        let analyzer = SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [transcriber],
            options: options
        )

        // Prepare the analyzer — this downloads the locale model if needed
        NSLog("[AppleSpeech] preparing analyzer, targetFormat: %.0fHz %dch %d", targetFormat.sampleRate, targetFormat.channelCount, targetFormat.commonFormat.rawValue)
        try await analyzer.prepareToAnalyze(in: targetFormat) { progress in
            NSLog("[AppleSpeech] model download progress: %.0f%%", progress.fractionCompleted * 100)
        }
        NSLog("[AppleSpeech] analyzer prepared, model ready")

        let state = self.sessionState
        let langCode = resolvedLocale.language.languageCode?.identifier

        // Store audio pipeline BEFORE creating output stream — prevents race where
        // sendAudio() is called before inputContinuation is stored.
        await state.storeAudioPipeline(
            analyzer: analyzer,
            transcriber: transcriber,
            converter: converter,
            targetFormat: targetFormat,
            inputContinuation: inputContinuation
        )
        NSLog("[AppleSpeech] audio pipeline stored, ready for sendAudio")

        // Create the output stream for transcript deltas
        let stream = AsyncThrowingStream<TranscriptDelta, Error> { continuation in
            Task {
                await state.storeOutputContinuation(continuation)

                // Start iterating results in a background task
                NSLog("[AppleSpeech] starting result iteration task")
                let iterationTask = Task {
                    do {
                        var resultCount = 0
                        for try await result in transcriber.results {
                            resultCount += 1
                            let text = String(result.text.characters)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            NSLog(
                                "[AppleSpeech] result #%d: isFinal=%d characters=%d",
                                resultCount,
                                result.isFinal ? 1 : 0,
                                text.count
                            )
                            guard !text.isEmpty else { continue }

                            await state.yieldDelta(TranscriptDelta(
                                text: text,
                                isFinal: result.isFinal,
                                language: langCode
                            ))
                        }
                        // Stream ended normally
                        await state.finishStream()
                    } catch {
                        if error is CancellationError || Task.isCancelled { return }
                        NSLog("[Cadenza] Apple speech realtime error: %@", error.localizedDescription)
                        await state.finishStream(
                            throwing: TranscriptionError.userVisible(from: error)
                        )
                    }
                }

                await state.setIterationTask(iterationTask)
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    let (_, iterationTask, _, _) = await state.teardown()
                    iterationTask?.cancel()
                }
            }
        }

        return stream
    }

    private var sendAudioCount = 0

    func sendAudio(_ data: Data) async throws {
        let (converter, targetFormat, inputContinuation) = await sessionState.getAudioPipeline()

        guard let inputContinuation else {
            sendAudioCount += 1
            if sendAudioCount <= 3 {
                NSLog("[AppleSpeech] sendAudio: inputContinuation is nil, dropping audio chunk #%d", sendAudioCount)
            }
            return
        }

        // Convert raw PCM16 data to AVAudioPCMBuffer in input format
        nonisolated(unsafe) let inputBuffer = try Self.dataToBuffer(data, format: Self.inputFormat)

        let outputBuffer: AVAudioPCMBuffer
        if let converter, let targetFormat {
            // Convert to the target format the analyzer expects
            let frameCapacity = AVAudioFrameCount(
                ceil(Double(inputBuffer.frameLength) * targetFormat.sampleRate / Self.inputFormat.sampleRate)
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                return
            }
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if let error {
                throw TranscriptionError.apiError("Audio conversion failed: \(error.localizedDescription)")
            }
            outputBuffer = converted
        } else {
            outputBuffer = inputBuffer
        }

        let input = AnalyzerInput(buffer: outputBuffer)
        inputContinuation.yield(input)
    }

    func stopRealtimeSession() async throws {
        let (analyzer, iterationTask, inputContinuation) = await sessionState.stopSnapshot()

        // Signal end of input
        inputContinuation?.finish()

        // Finalize the analyzer
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        await iterationTask?.value
        await sessionState.clearStopResources()
        await sessionState.finishStream()
    }

    // MARK: - Helpers

    /// Convert raw PCM data to an AVAudioPCMBuffer.
    private static func dataToBuffer(_ data: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            throw TranscriptionError.apiError("Invalid audio format: zero bytes per frame")
        }
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frameCount > 0 else {
            throw TranscriptionError.apiError("Audio data too small to form a frame")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriptionError.apiError("Failed to create audio buffer")
        }
        buffer.frameLength = frameCount

        // Copy raw bytes into the buffer
        if format.commonFormat == .pcmFormatInt16 {
            guard let int16Data = buffer.int16ChannelData else {
                throw TranscriptionError.apiError("Failed to access int16 channel data")
            }
            data.withUnsafeBytes { rawPtr in
                let src = rawPtr.bindMemory(to: Int16.self)
                int16Data[0].update(from: src.baseAddress!, count: Int(frameCount))
            }
        } else if format.commonFormat == .pcmFormatFloat32 {
            guard let floatData = buffer.floatChannelData else {
                throw TranscriptionError.apiError("Failed to access float channel data")
            }
            data.withUnsafeBytes { rawPtr in
                let src = rawPtr.bindMemory(to: Float.self)
                floatData[0].update(from: src.baseAddress!, count: Int(frameCount))
            }
        } else {
            throw TranscriptionError.apiError("Unsupported audio format: \(format.commonFormat.rawValue)")
        }

        return buffer
    }

    // MARK: - File Format Conversion

    private static let convertQueue = DispatchQueue(label: "com.cadenza.apple-speech-convert")

    /// Convert an audio file to 16kHz mono Int16 PCM WAV for SpeechAnalyzer compatibility.
    private static func convertToSpeechFormat(_ inputURL: URL) async throws -> URL {
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
            writerInput.requestMediaDataWhenReady(on: convertQueue) {
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
}
