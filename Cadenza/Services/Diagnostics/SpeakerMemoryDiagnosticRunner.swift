import Foundation

@Observable @MainActor
final class SpeakerMemoryDiagnosticRunner {
    static let shared = SpeakerMemoryDiagnosticRunner()

    private(set) var isRunning = false
    private(set) var currentStatus = ""
    private(set) var report = ""

    private init() {}

    func run(audioURL: URL) async {
        guard !isRunning else { return }
        isRunning = true
        report = ""
        defer { isRunning = false; currentStatus = "" }

        let startTime = Date()
        log("=== Speaker Memory POC Diagnostic ===")
        log("Audio: \(audioURL.lastPathComponent)")

        // Step 1: Extract embeddings
        currentStatus = "Extracting embeddings..."
        log("")
        log("== EMBEDDING EXTRACTION ==")
        log("")

        let extractor = SpeakerKitEmbeddingExtractor()
        let result: SpeakerEmbeddingResult
        do {
            result = try await extractor.extractEmbeddings(from: audioURL)
        } catch {
            log("ERROR: Extraction failed: \(error.localizedDescription)")
            return
        }

        log("Model version: \(result.modelVersion)")
        log("Speakers detected: \(result.speakerCount)")
        log("Embedding dimension: \(result.embeddingDimension)")
        log("Total windows: \(result.embeddings.count)")

        // Per-speaker window breakdown
        let grouped = Dictionary(grouping: result.embeddings, by: \.rawSpeakerIndex)
        for speakerIndex in grouped.keys.sorted() {
            let windows = grouped[speakerIndex]!
            let avgNonOverlap = windows.reduce(Float(0)) { $0 + $1.nonOverlapRatio } / Float(windows.count)
            log("  Speaker \(speakerIndex + 1): \(windows.count) windows, avg nonOverlapRatio=\(String(format: "%.2f", avgNonOverlap))")
        }

        // Step 2: Build centroids
        currentStatus = "Computing centroids..."
        log("")
        log("== CENTROIDS ==")
        log("")

        let service = SpeakerMemoryService(config: .default)
        let centroids = service.buildCentroids(from: result)

        if centroids.isEmpty {
            log("No speakers passed quality gates.")
            log("  minimumNonOverlapRatio: \(service.config.minimumNonOverlapRatio)")
            log("  minimumSpeechSeconds: \(service.config.minimumSpeechSeconds)")
        }

        // Pre-normalize all centroids once for reuse across all report sections
        let normalizedCentroids = centroids.map { SpeakerMemoryService.l2Normalize($0.centroid) }

        for (idx, c) in centroids.enumerated() {
            let preview = normalizedCentroids[idx].prefix(4).map { String(format: "%.4f", $0) }.joined(separator: ", ")
            log("Speaker \(c.rawSpeakerIndex + 1):")
            log("  Windows kept: \(c.windowCount)")
            log("  Non-overlapped speech: \(String(format: "%.1f", c.totalSpeechSeconds))s")
            log("  Centroid preview (L2-normed): [\(preview), ...]")
        }

        // Step 3: Cross-speaker cosine similarity matrix
        currentStatus = "Computing similarity matrix..."
        log("")
        log("== CROSS-SPEAKER SIMILARITY ==")
        log("")

        if centroids.count < 2 {
            log("Need ≥2 speakers for cross-speaker comparison.")
        } else {
            var header = "         "
            for c in centroids { header += String(format: "Spk%-5d", c.rawSpeakerIndex + 1) }
            log(header)

            for i in 0..<centroids.count {
                var row = String(format: "Spk%-5d", centroids[i].rawSpeakerIndex + 1)
                for j in 0..<centroids.count {
                    let score = SpeakerMemoryService.cosineSimilarity(normalizedCentroids[i], normalizedCentroids[j])
                    row += String(format: " %6.3f  ", score)
                }
                log(row)
            }
        }

        // Step 4: Self-consistency check (within-speaker window variance)
        currentStatus = "Analyzing within-speaker variance..."
        log("")
        log("== WITHIN-SPEAKER CONSISTENCY ==")
        log("")

        for (idx, c) in centroids.enumerated() {
            let windows = grouped[c.rawSpeakerIndex] ?? []
            let accepted = service.filterWindows(windows, minimumNonOverlapRatio: service.config.minimumNonOverlapRatio)

            let scores = accepted.map { w in
                SpeakerMemoryService.cosineSimilarity(
                    SpeakerMemoryService.l2Normalize(w.embedding),
                    normalizedCentroids[idx]
                )
            }

            if scores.isEmpty { continue }

            let minScore = scores.min() ?? 0
            let maxScore = scores.max() ?? 0
            let avgScore = scores.reduce(0, +) / Float(scores.count)

            log("Speaker \(c.rawSpeakerIndex + 1): min=\(String(format: "%.3f", minScore)) avg=\(String(format: "%.3f", avgScore)) max=\(String(format: "%.3f", maxScore)) (n=\(scores.count))")
        }

        let elapsed = Date().timeIntervalSince(startTime)
        log("")
        log("=== Done in \(String(format: "%.1f", elapsed))s ===")

        do {
            let reportURL = try DiagnosticArtifactStore.shared.writeReport(
                prefix: "speaker-memory",
                contents: report,
                maximumBytes: 5 * 1_024 * 1_024
            )
            NSLog("[SpeakerMemory] private report saved: %@", reportURL.lastPathComponent)
        } catch {
            NSLog("[SpeakerMemory] report save failed: %@", error.localizedDescription)
        }
    }

    private func log(_ line: String) {
        report += line + "\n"
    }
}
