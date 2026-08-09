import AVFoundation
import Foundation
import WhisperKit

/// Runs functional verification of all AI pipelines against a local audio file.
@Observable @MainActor
final class FunctionalTestRunner {
    static let shared = FunctionalTestRunner()

    private(set) var isRunning = false
    private(set) var currentStatus = ""
    private(set) var report = ""

    private static let cloudClipDuration: TimeInterval = 60
    private static let testTimeout: TimeInterval = 180

    private init() {}

    func run(audioURL: URL) async {
        guard !isRunning else { return }
        isRunning = true
        report = ""
        defer { isRunning = false; currentStatus = "" }

        let startTime = Date()
        log("=== Cadenza Functional Test ===")
        log("Audio: \(audioURL.lastPathComponent)")

        let duration: TimeInterval
        do {
            let asset = AVURLAsset(url: audioURL)
            duration = try await asset.load(.duration).seconds
            log("Duration: \(String(format: "%.0f", duration))s")
        } catch {
            log("ERROR: Cannot read audio: \(error.localizedDescription)")
            return
        }

        // Prepare clips
        let shortClipURL = (duration > 70) ? (try? await createClip(from: audioURL, duration: Self.cloudClipDuration)) : nil
        defer { if let u = shortClipURL { try? FileManager.default.removeItem(at: u) } }

        // Config snapshot
        log("")
        log("== CONFIGURATION ==")
        log("")
        logConfigSnapshot()

        log("")
        log("== TRANSCRIPTION ==")
        log("")

        let transcriptionProviders = collectTranscriptionProviders()
        var rawTranscripts: [String] = []

        for (provider, apiKey) in transcriptionProviders {
            let isCloud = provider.requiresAPIKey
            let testURL = (isCloud && shortClipURL != nil) ? shortClipURL! : audioURL
            let suffix = (isCloud && shortClipURL != nil) ? " [60s clip]" : " [full]"

            let result: TranscriptTestResult? = await runWithTimeout(label: "\(provider.displayName)\(suffix)") {
                try await self.transcribe(provider: provider, apiKey: apiKey, audioURL: testURL)
            }
            if let r = result {
                rawTranscripts.append(r.rawText)
            }
        }

        log("")
        log("== SUMMARY ==")
        log("")

        let bestTranscript = rawTranscripts.max(by: { $0.count < $1.count }) ?? ""
        if bestTranscript.isEmpty {
            log("SKIP: No transcript available")
        } else {
            let summaryProviders = collectSummaryProviders()
            for (provider, apiKey) in summaryProviders {
                // Size input to provider's context capacity
                let maxInput: Int
                switch provider {
                case .apple: maxInput = 800     // Apple FM: ~4K token total, need room for prompt + output
                default: maxInput = bestTranscript.count // cloud: full
                }
                let input = String(bestTranscript.prefix(maxInput))

                await runWithTimeout(label: "\(provider.displayName) [\(input.count) chars input]") {
                    try await self.summarize(provider: provider, apiKey: apiKey, transcript: input)
                }
            }
        }

        log("")
        log("== SPEAKER DIARIZATION ==")
        log("")

        // Use full audio for diarization (it's fast)
        await runWithTimeout(label: "SpeakerKit [full audio]") {
            let result = try await SpeakerDiarizer.shared.diarize(audioURL: audioURL)
            return "\(result.speakerCount) speakers, \(result.segments.count) segments"
        }

        let elapsed = Date().timeIntervalSince(startTime)
        log("")
        log("=== Done in \(String(format: "%.1f", elapsed))s ===")

        do {
            let reportURL = try DiagnosticArtifactStore.shared.writeReport(
                prefix: "functional-test",
                contents: report,
                maximumBytes: 5 * 1_024 * 1_024
            )
            NSLog("[FunctionalTest] private report saved: %@", reportURL.lastPathComponent)
        } catch {
            NSLog("[FunctionalTest] report save failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Timeout Wrapper

    @discardableResult
    private func runWithTimeout<T: Sendable>(label: String, task: @Sendable @escaping () async throws -> T) async -> T? where T: CustomStringConvertible {
        currentStatus = label
        log("[\(label)]")
        let start = Date()

        do {
            let result = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await task() }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.testTimeout))
                    throw CancellationError()
                }
                let value = try await group.next()!
                group.cancelAll()
                return value
            }
            let elapsed = Date().timeIntervalSince(start)
            log("  ✓ \(result) (\(String(format: "%.1f", elapsed))s)")
            return result
        } catch is CancellationError {
            let elapsed = Date().timeIntervalSince(start)
            log("  ✗ TIMEOUT after \(String(format: "%.0f", elapsed))s")
            return nil
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            log("  ✗ \(error.localizedDescription) (\(String(format: "%.1f", elapsed))s)")
            return nil
        }
    }

    // MARK: - Transcription

    private struct TranscriptTestResult: CustomStringConvertible, Sendable {
        let diagnostics: String
        let rawText: String
        var description: String { diagnostics }
    }

    private func transcribe(provider: AIProvider, apiKey: String, audioURL: URL) async throws -> TranscriptTestResult {
        let manager = TranscriptionManager()
        _ = try await manager.transcribeFile(at: audioURL, provider: provider, apiKey: apiKey, language: nil)
        let text = manager.fullText
        let segCount = manager.segments.count
        let speakerCount = Set(manager.segments.compactMap(\.speaker)).count
        manager.reset()
        guard !text.isEmpty else { throw TestError.empty("empty transcript") }
        let diag = "\(text.count) chars, \(segCount) segs, \(speakerCount) speakers — \"\(String(text.prefix(60)))…\""
        return TranscriptTestResult(diagnostics: diag, rawText: text)
    }

    // MARK: - Summary

    private func summarize(provider: AIProvider, apiKey: String, transcript: String) async throws -> String {
        guard let service = provider.makeChatService(apiKey: apiKey) else {
            throw TestError.empty("service unavailable")
        }
        let result = try await service.summarize(
            transcript: transcript, language: "en", model: provider.summaryModel,
            jobTitle: nil, meetingType: nil, meetingTitle: nil
        )
        guard !result.overview.isEmpty else { throw TestError.empty("empty overview") }
        return "title=\"\(result.title)\", overview=\(result.overview.count)ch, keyPts=\(result.keyPoints.count), actions=\(result.actionItems.count)"
    }

    // MARK: - Audio Clip

    private func createClip(from sourceURL: URL, duration: TimeInterval) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_clip_\(UUID().uuidString).m4a")
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TestError.empty("No audio track in source file")
        }
        let timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        try await AudioExporter.exportToM4A(asset: asset, track: track, outputURL: outputURL, settings: .clipQuality, timeRange: timeRange)
        return outputURL
    }

    // MARK: - Provider Collection

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

    private func collectSummaryProviders() -> [(AIProvider, String)] {
        var p: [(AIProvider, String)] = []
        if AppleFoundationModelFactory.isAvailable { p.append((.apple, "")) }
        for provider in [AIProvider.openai, .gemini, .claude, .minimax] {
            if let key = KeychainManager.shared.apiKey(for: provider), !key.isEmpty { p.append((provider, key)) }
        }
        return p
    }

    private func logConfigSnapshot() {
        let ud = UserDefaults.standard
        let txProvider = ud.string(forKey: "transcriptionProvider") ?? "apple"
        let aiProvider = ud.string(forKey: "defaultAIProvider") ?? "apple"
        let txLang = ud.string(forKey: "transcriptionLanguage") ?? "auto"
        let rtEnabled = ud.bool(forKey: "enableRealtimeTranscription")
        let rtProvider = ud.string(forKey: "realtimeTranscriptionProvider") ?? "openai"
        let diarEnabled = ud.bool(forKey: "diarization.enabled")
        let whisperModel = WhisperModelManager.shared.selectedModel
        let whisperReady = WhisperModelManager.shared.isAvailable(whisperModel)
        let appleFM = AppleFoundationModelFactory.isAvailable
        let speakerReady = SpeakerDiarizer.shared.isReady

        log("Transcription provider: \(txProvider)")
        log("Transcription language: \(txLang)")
        log("AI provider: \(aiProvider)")
        log("Realtime: \(rtEnabled ? "ON (\(rtProvider))" : "OFF")")
        log("Diarization: \(diarEnabled ? "ON" : "OFF"), model \(speakerReady ? "ready" : "not ready")")
        log("Whisper model: \(whisperModel) \(whisperReady ? "✓" : "✗")")
        log("Apple FM: \(appleFM ? "✓" : "✗")")

        // API keys
        for p in [AIProvider.openai, .gemini, .claude, .minimax] {
            let has = KeychainManager.shared.hasAPIKey(for: p)
            log("\(p.displayName) key: \(has ? "✓" : "✗")")
        }
    }

    private func log(_ message: String) {
        report += message + "\n"
    }

    private enum TestError: LocalizedError {
        case empty(String)
        var errorDescription: String? { switch self { case .empty(let m): return m } }
    }
}
