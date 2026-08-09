import AVFoundation
import Foundation
import WhisperKit

/// Compares transcription and summary quality across all available providers.
/// Outputs a side-by-side report for human review.
@Observable @MainActor
final class QualityComparisonRunner {
    static let shared = QualityComparisonRunner()

    private(set) var isRunning = false
    private(set) var currentStatus = ""
    private(set) var report = ""

    /// Use first 2 minutes for all providers to keep test fair and fast.
    private static let testDuration: TimeInterval = 120
    /// Realtime test feeds ~30s of audio.
    private static let realtimeDuration: TimeInterval = 30
    private static let testTimeout: TimeInterval = 180
    private static let realtimeConnectTimeout: Duration = .seconds(10)

    private init() {}

    /// Run only the realtime transcription test — much faster than full comparison.
    func runRealtimeOnly(audioURL: URL) async {
        guard !isRunning else { return }
        isRunning = true
        report = ""
        defer { isRunning = false; currentStatus = "" }

        let startTime = Date()
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("  REALTIME TRANSCRIPTION TEST")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("")
        log("Source: \(audioURL.lastPathComponent)")

        let realtimeAudio24k = await prepareRealtimeAudio(from: audioURL, sampleRate: 24000)
        let realtimeAudio16k = await prepareRealtimeAudio(from: audioURL, sampleRate: 16000)

        guard realtimeAudio24k != nil || realtimeAudio16k != nil else {
            log("ERROR: Could not prepare audio")
            return
        }

        for (provider, apiKey) in collectRealtimeProviders() {
            let chunks = (provider == .gemini ? realtimeAudio16k : realtimeAudio24k) ?? []
            if !chunks.isEmpty {
                await testRealtime(provider: provider, apiKey: apiKey, audioChunks: chunks)
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        log("")
        log("═══ Total: \(String(format: "%.1f", elapsed))s ═══")
        log("")
        log("Check Console logs for detailed protocol messages:")
        log("  [RealtimeTranscriber] — OpenAI events")
        log("  [GeminiRealtime] — Gemini messages")
    }

    func run(audioURL: URL) async {
        guard !isRunning else { return }
        isRunning = true
        report = ""
        defer { isRunning = false; currentStatus = "" }

        let startTime = Date()
        log("╔══════════════════════════════════════╗")
        log("║   Cadenza Quality Comparison Report  ║")
        log("╚══════════════════════════════════════╝")
        log("")
        log("Source: \(audioURL.lastPathComponent)")

        let duration: TimeInterval
        do {
            let asset = AVURLAsset(url: audioURL)
            duration = try await asset.load(.duration).seconds
            log("Duration: \(String(format: "%.0f", duration))s")
        } catch {
            log("ERROR: \(error.localizedDescription)")
            return
        }

        // Create a 2-min clip for fair comparison
        let clipURL: URL?
        if duration > Self.testDuration + 10 {
            log("Using first \(Int(Self.testDuration))s for all providers")
            clipURL = try? await createClip(from: audioURL, duration: Self.testDuration)
        } else {
            clipURL = nil
        }
        defer { if let u = clipURL { try? FileManager.default.removeItem(at: u) } }
        let testURL = clipURL ?? audioURL

        // ════════════════════════════════════════
        // TRANSCRIPTION COMPARISON
        // ════════════════════════════════════════
        log("")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("  TRANSCRIPTION COMPARISON")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        var transcriptResults: [(name: String, text: String, segments: Int, speakers: Int, time: TimeInterval)] = []

        for (provider, apiKey) in collectTranscriptionProviders() {
            currentStatus = "Transcribing: \(provider.displayName)"
            let start = Date()

            let manager = TranscriptionManager()
            do {
                try await withTimeout(Self.testTimeout) {
                    _ = try await manager.transcribeFile(
                        at: testURL, provider: provider, apiKey: apiKey, language: nil
                    )
                }
                let elapsed = Date().timeIntervalSince(start)
                let text = manager.fullText
                let segs = manager.segments.count
                let speakers = Set(manager.segments.compactMap(\.speaker)).count
                manager.reset()

                if !text.isEmpty {
                    transcriptResults.append((provider.displayName, text, segs, speakers, elapsed))
                } else {
                    transcriptResults.append((provider.displayName, "(empty)", 0, 0, elapsed))
                }
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                transcriptResults.append((provider.displayName, "(FAILED: \(error.localizedDescription))", 0, 0, elapsed))
                manager.reset()
            }
        }

        // Print transcription comparison table
        log("")
        log(pad("Provider", 18) + pad("Chars", 9) + pad("Segs", 7) + pad("Speakers", 9) + pad("Time", 8))
        log(String(repeating: "─", count: 52))
        for r in transcriptResults {
            log(pad(r.name, 18) + pad("\(r.text.count)", 9) + pad("\(r.segments)", 7) + pad("\(r.speakers)", 9) + pad(String(format: "%.1fs", r.time), 8))
        }

        // Show first 200 chars of each transcript
        log("")
        log("── Transcript Previews (first 200 chars) ──")
        for r in transcriptResults {
            log("")
            log("[\(r.name)]")
            let preview = String(r.text.prefix(200))
            log(preview)
        }

        // ════════════════════════════════════════
        // REALTIME TRANSCRIPTION COMPARISON
        // ════════════════════════════════════════
        log("")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("  REALTIME TRANSCRIPTION (simulated)")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Prepare PCM audio for realtime tests (24kHz for Apple/OpenAI, 16kHz for Gemini)
        let realtimeAudio24k = await prepareRealtimeAudio(from: testURL, sampleRate: 24000)
        let realtimeAudio16k = await prepareRealtimeAudio(from: testURL, sampleRate: 16000)
        if realtimeAudio24k != nil || realtimeAudio16k != nil {
            for (provider, apiKey) in collectRealtimeProviders() {
                let chunks = (provider == .gemini ? realtimeAudio16k : realtimeAudio24k) ?? []
                if !chunks.isEmpty {
                    await testRealtime(provider: provider, apiKey: apiKey, audioChunks: chunks)
                }
            }
        } else {
            log("")
            log("SKIP: Could not prepare audio for realtime test")
        }

        // ════════════════════════════════════════
        // SUMMARY COMPARISON
        // ════════════════════════════════════════
        log("")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("  SUMMARY COMPARISON")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Use the best (longest) transcript
        let bestTranscript = transcriptResults.max(by: { $0.text.count < $1.text.count })?.text ?? ""
        guard !bestTranscript.isEmpty, bestTranscript != "(empty)" else {
            log("\nSKIP: No transcript available")
            finishReport(startTime: startTime)
            return
        }

        var summaryResults: [(name: String, title: String, overview: Int, keyPts: Int, actions: Int, decisions: Int, time: TimeInterval, failed: Bool)] = []

        for (provider, apiKey) in collectSummaryProviders() {
            currentStatus = "Summarizing: \(provider.displayName)"
            let maxInput: Int
            switch provider {
            case .apple: maxInput = 800
            default: maxInput = bestTranscript.count
            }
            let input = String(bestTranscript.prefix(maxInput))
            let start = Date()

            do {
                guard let service = provider.makeChatService(apiKey: apiKey) else {
                    throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "service unavailable"])
                }
                let result = try await withTimeout(Self.testTimeout) {
                    try await service.summarize(
                        transcript: input, language: "en", model: provider.summaryModel,
                        jobTitle: nil, meetingType: nil, meetingTitle: nil
                    )
                }
                let elapsed = Date().timeIntervalSince(start)
                summaryResults.append((
                    provider.displayName, result.title, result.overview.count,
                    result.keyPoints.count, result.actionItems.count,
                    result.decisions.count, elapsed, false
                ))
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                summaryResults.append((provider.displayName, error.localizedDescription, 0, 0, 0, 0, elapsed, true))
            }
        }

        // Print summary comparison table
        log("")
        log(pad("Provider", 18) + pad("Overview", 9) + pad("KeyPts", 7) + pad("Actions", 8) + pad("Decide", 8) + pad("Time", 8))
        log(String(repeating: "─", count: 58))
        for r in summaryResults {
            if r.failed {
                log(pad(r.name, 18) + " FAIL: \(r.title)")
            } else {
                log(pad(r.name, 18) + pad("\(r.overview)ch", 9) + pad("\(r.keyPts)", 7) + pad("\(r.actions)", 8) + pad("\(r.decisions)", 8) + pad(String(format: "%.1fs", r.time), 8))
            }
        }

        // Show titles and overview previews
        log("")
        log("── Summary Previews ──")
        for r in summaryResults where !r.failed {
            log("")
            log("[\(r.name)] \"\(r.title)\"")
        }

        finishReport(startTime: startTime)
    }

    // MARK: - Realtime Test

    private func testRealtime(provider: AIProvider, apiKey: String, audioChunks: [Data]) async {
        currentStatus = "Realtime: \(provider.displayName)"
        log("")
        log("[\(provider.displayName)] (\(audioChunks.count) chunks, \(audioChunks.first?.count ?? 0) bytes each)")

        let manager = TranscriptionManager()
        let start = Date()
        let language = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        var didConnect = false

        do {
            log("  Connecting...")
            log("  Language hint: \((language == nil || language == "auto") ? "auto" : language!)")
            RealtimeDebugLog.shared.clear()

            try await Self.startRealtimeWithDeadline(
                manager: manager,
                provider: provider,
                apiKey: apiKey,
                language: language,
                timeout: Self.realtimeConnectTimeout
            )
            didConnect = true
            log("  Connected, isTranscribing=\(manager.isTranscribing)")

            // Feed audio in real-time-ish pace.
            // Yield to MainActor between chunks so drainAudioQueue can process.
            var fed = 0
            for chunk in audioChunks {
                guard manager.isTranscribing else {
                    log("  Stopped transcribing after \(fed) chunks")
                    break
                }
                manager.sendAudio(chunk)
                fed += 1
                // Yield every chunk to let drain/receive run on MainActor
                try await Task.sleep(for: .milliseconds(100))
            }
            log("  Fed \(fed)/\(audioChunks.count) chunks, sendAudioCount=\(manager.sendAudioCount)")

            // Flush and wait for processing
            await manager.flushRealtimeAudio()
            try await Task.sleep(for: .seconds(5))
            await manager.stopRealtime(preserveRealtimeError: true, awaitFinalDeltas: true)
            let elapsed = Date().timeIntervalSince(start)
            let text = realtimeDiagnosticText(from: manager)
            let segCount = manager.segments.count
            let rtError = manager.realtimeError

            // Dump protocol log
            let events = RealtimeDebugLog.shared.entries
            if !events.isEmpty {
                log("  Protocol (\(events.count) events):")
                for e in events.suffix(15) {
                    log("    \(e)")
                }
                if events.count > 15 { log("    ... (\(events.count - 15) more)") }
            }

            if let rtError {
                log("  ✗ Realtime error: \(rtError) (\(String(format: "%.1f", elapsed))s)")
            } else if text.isEmpty {
                log("  ✗ No output after \(fed) chunks (\(String(format: "%.1f", elapsed))s)")
            } else {
                log("  ✓ \(text.count) chars, \(segCount) segs (\(String(format: "%.1f", elapsed))s)")
                log("  Preview: \(String(text.prefix(120)))…")
            }
            manager.reset()
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            if didConnect {
                await manager.stopRealtime(preserveRealtimeError: true)
            }
            manager.reset()
            log("  ✗ \(error.localizedDescription) (\(String(format: "%.1f", elapsed))s)")
        }
    }

    private func realtimeDiagnosticText(from manager: TranscriptionManager) -> String {
        let finalText = manager.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSegments = manager.segments
            .filter(\.isFinal)
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trailingLive = manager.segments.last(where: { !$0.isFinal })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let trailingLive, !trailingLive.isEmpty {
            if finalSegments.isEmpty {
                return trailingLive
            }
            let finalized = finalSegments.joined(separator: " ")
            return finalized.isEmpty ? trailingLive : "\(finalized) \(trailingLive)"
        }

        if !finalText.isEmpty {
            return finalText
        }

        return finalSegments.joined(separator: " ")
    }

    static func startRealtimeWithDeadline(
        manager: TranscriptionManager,
        provider: AIProvider,
        apiKey: String,
        language: String?,
        timeout: Duration
    ) async throws {
        let recordingStartTime = Date()
        let attemptID = RealtimeAttemptID()
        do {
            try await HardAsyncDeadline.run(for: timeout) {
                try await manager.startRealtime(
                    provider: provider,
                    apiKey: apiKey,
                    language: language,
                    recordingStartTime: recordingStartTime,
                    attemptID: attemptID
                )
            }
        } catch {
            // Revoke only this startup attempt. It may have timed out after its
            // provider already released pending ownership and a replacement
            // acquired the manager.
            if let cleanup = manager.beginRealtimeStop(
                matching: attemptID,
                preserveRealtimeError: true
            ) {
                await manager.finishRealtimeStop(cleanup, abandonStartup: true)
            }
            throw error
        }
    }

    /// Prepare 30s of mono Int16 PCM audio split into ~100ms chunks for realtime feeding.
    private func prepareRealtimeAudio(from url: URL, sampleRate: Int = 24000) async -> [Data]? {
        do {
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            // Only read first 30s
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: Self.realtimeDuration, preferredTimescale: 600))
            reader.add(output)
            reader.startReading()

            // 100ms chunks: sampleRate * 0.1 * 2 bytes per sample
            let chunkBytes = sampleRate / 10 * 2
            var allData = Data()
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var raw = [UInt8](repeating: 0, count: length)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &raw)
                allData.append(contentsOf: raw)
            }

            // Split into chunks
            var chunks: [Data] = []
            var offset = 0
            while offset + chunkBytes <= allData.count {
                chunks.append(allData[offset..<offset + chunkBytes])
                offset += chunkBytes
            }
            return chunks.isEmpty ? nil : chunks
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    static func runWithDeadline<T: Sendable>(
        timeout: Duration,
        work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await HardAsyncDeadline.run(for: timeout, operation: work)
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @Sendable @escaping () async throws -> T) async throws -> T {
        try await Self.runWithDeadline(
            timeout: .seconds(seconds),
            work: work
        )
    }

    private func createClip(from sourceURL: URL, duration: TimeInterval) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality_clip_\(UUID().uuidString).m4a")
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "QualityRunner", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio track"])
        }
        let timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        try await AudioExporter.exportToM4A(asset: asset, track: track, outputURL: outputURL, settings: .clipQuality, timeRange: timeRange)
        return outputURL
    }

    private func collectTranscriptionProviders() -> [(AIProvider, String)] {
        var p: [(AIProvider, String)] = []
        let wm = WhisperModelManager.shared
        if wm.isAvailable(wm.selectedModel) { p.append((.whisperLocal, "")) }
        if AppleSpeechFactory.isSupportedOnCurrentOS { p.append((.apple, "")) }
        for provider in [AIProvider.openai, .gemini] {
            if let key = KeychainManager.shared.apiKey(for: provider), !key.isEmpty { p.append((provider, key)) }
        }
        return p
    }

    private func collectRealtimeProviders() -> [(AIProvider, String)] {
        var p: [(AIProvider, String)] = []
        if AppleSpeechFactory.isSupportedOnCurrentOS { p.append((.apple, "")) }
        for provider in [AIProvider.openai, .gemini] {
            if let key = KeychainManager.shared.apiKey(for: provider), !key.isEmpty { p.append((provider, key)) }
        }
        return p
    }

    private func collectSummaryProviders() -> [(AIProvider, String)] {
        var p: [(AIProvider, String)] = []
        if AppleFoundationModelFactory.isAvailable { p.append((.apple, "")) }
        for provider in [AIProvider.openai, .gemini, .claude, .minimax] {
            if let key = KeychainManager.shared.apiKey(for: provider), !key.isEmpty { p.append((provider, key)) }
        }
        return p
    }

    private func finishReport(startTime: Date) {
        let elapsed = Date().timeIntervalSince(startTime)
        log("")
        log("═══ Total: \(String(format: "%.1f", elapsed))s ═══")

        do {
            let reportURL = try DiagnosticArtifactStore.shared.writeReport(
                prefix: "quality-comparison",
                contents: report,
                maximumBytes: 5 * 1_024 * 1_024
            )
            NSLog("[QualityComparison] private report saved: %@", reportURL.lastPathComponent)
        } catch {
            NSLog("[QualityComparison] report save failed: %@", error.localizedDescription)
        }
    }

    private func pad(_ str: String, _ width: Int) -> String {
        str.count >= width ? str : str + String(repeating: " ", count: width - str.count)
    }

    private func log(_ message: String) {
        report += message + "\n"
    }
}
