import Foundation

/// Runs the speaker memory pipeline across a labeled corpus and reports precision/recall.
///
/// Corpus JSON format:
/// ```json
/// [
///   {
///     "audioFile": "meeting-2026-03-15.m4a",
///     "speakers": { "SPEAKER_00": "alice", "SPEAKER_01": "bob" }
///   }
/// ]
/// ```
///
/// Speaker identity keys (e.g. "alice", "bob") must be consistent across recordings
/// to test cross-recording recognition.
@MainActor
final class SpeakerMemoryEvaluator {
    struct CorpusEntry: Codable {
        let audioFile: String
        let speakers: [String: String]  // raw diarization label → identity name
    }

    struct EvaluationResult {
        let totalSuggestions: Int
        let correctSuggestions: Int    // suggestion matched the labeled identity
        let incorrectSuggestions: Int  // suggestion matched wrong identity
        let missedSpeakers: Int        // labeled speaker got no suggestion
        var precision: Float { totalSuggestions > 0 ? Float(correctSuggestions) / Float(totalSuggestions) : 0 }
        var recall: Float { (correctSuggestions + missedSpeakers) > 0 ? Float(correctSuggestions) / Float(correctSuggestions + missedSpeakers) : 0 }
    }

    private let extractor: SpeakerEmbeddingExtractorProtocol
    private let service: SpeakerMemoryService

    init(
        extractor: SpeakerEmbeddingExtractorProtocol = SpeakerKitEmbeddingExtractor(),
        service: SpeakerMemoryService = SpeakerMemoryService(config: .default)
    ) {
        self.extractor = extractor
        self.service = service
    }

    /// Runs evaluation on corpus.
    /// `corpusDir` is the directory containing the audio files.
    func evaluate(corpusURL: URL, corpusDir: URL, log: @escaping (String) -> Void) async -> EvaluationResult {
        log("=== Speaker Memory POC Evaluation ===")
        log("")

        // Parse corpus
        let entries: [CorpusEntry]
        do {
            let data = try Data(contentsOf: corpusURL)
            entries = try JSONDecoder().decode([CorpusEntry].self, from: data)
        } catch {
            log("ERROR: Cannot parse corpus: \(error)")
            return EvaluationResult(totalSuggestions: 0, correctSuggestions: 0, incorrectSuggestions: 0, missedSpeakers: 0)
        }

        log("Corpus: \(entries.count) recordings")

        // Phase 1: Extract all centroids and build a "confirmed" memory bank
        // Simulate the confirmation flow: process recordings in order,
        // treating the first occurrence of each identity as the "confirmation" seed,
        // and subsequent occurrences as match targets.
        var confirmedCentroids: [String: [(centroid: [Float], modelVersion: String)]] = [:]  // identity → centroids
        var identityToProfileID: [String: UUID] = [:]

        struct RecordingData {
            let entry: CorpusEntry
            let centroids: [SpeakerMemoryService.SpeakerCentroidResult]
            let speakerIndexToIdentity: [Int: String]
            let modelVersion: String
        }

        var allRecordingData: [RecordingData] = []

        for (idx, entry) in entries.enumerated() {
            let audioURL = corpusDir.appendingPathComponent(entry.audioFile)
            log("")
            log("[\(idx + 1)/\(entries.count)] \(entry.audioFile)")

            do {
                let result = try await extractor.extractEmbeddings(from: audioURL)
                let centroids = service.buildCentroids(from: result)

                // Build speakerIndex → identity mapping from corpus labels.
                var indexToIdentity: [Int: String] = [:]
                for (rawLabel, identity) in entry.speakers {
                    if let idx = parseSpeakerIndex(rawLabel) {
                        indexToIdentity[idx] = identity
                    }
                }

                for c in centroids {
                    let identity = indexToIdentity[c.rawSpeakerIndex]
                    log("  Speaker \(c.rawSpeakerIndex + 1) → \(identity ?? "unlabeled") (\(c.windowCount) windows, \(String(format: "%.1f", c.totalSpeechSeconds))s)")
                }

                allRecordingData.append(RecordingData(
                    entry: entry,
                    centroids: centroids,
                    speakerIndexToIdentity: indexToIdentity,
                    modelVersion: result.modelVersion
                ))
            } catch {
                log("  ERROR: \(error.localizedDescription)")
            }
        }

        // Phase 2: Simulate incremental matching
        log("")
        log("== MATCHING SIMULATION ==")
        log("")

        var totalSuggestions = 0
        var correct = 0
        var incorrect = 0
        var missed = 0

        for (idx, data) in allRecordingData.enumerated() {
            log("[\(idx + 1)] \(data.entry.audioFile)")

            for centroid in data.centroids {
                guard let trueIdentity = data.speakerIndexToIdentity[centroid.rawSpeakerIndex] else { continue }

                // Build confirmed samples from all OTHER recordings' confirmed centroids
                var samples: [SpeakerMemoryService.ProfileSample] = []
                for (identity, centroidList) in confirmedCentroids {
                    let profileID = identityToProfileID[identity]!
                    for c in centroidList {
                        samples.append(.init(
                            profileID: profileID,
                            centroid: c.centroid,
                            modelVersion: c.modelVersion,
                            sampleCount: centroidList.count
                        ))
                    }
                }

                let normalizedCentroid = SpeakerMemoryService.l2Normalize(centroid.centroid)
                let match = service.matchSpeaker(
                    centroid: normalizedCentroid,
                    confirmedSamples: samples,
                    currentModelVersion: data.modelVersion
                )

                if let match = match {
                    let matchedIdentity = identityToProfileID.first(where: { $0.value == match.profileID })?.key ?? "?"
                    totalSuggestions += 1
                    if matchedIdentity == trueIdentity {
                        correct += 1
                        log("  Speaker \(centroid.rawSpeakerIndex + 1) (\(trueIdentity)): ✓ matched \(matchedIdentity) (score=\(String(format: "%.3f", match.score)))")
                    } else {
                        incorrect += 1
                        log("  Speaker \(centroid.rawSpeakerIndex + 1) (\(trueIdentity)): ✗ wrong match \(matchedIdentity) (score=\(String(format: "%.3f", match.score)))")
                    }
                } else {
                    if confirmedCentroids[trueIdentity] != nil {
                        // We had a confirmed sample for this identity but didn't match
                        missed += 1
                        log("  Speaker \(centroid.rawSpeakerIndex + 1) (\(trueIdentity)): – no suggestion (missed)")
                    } else {
                        log("  Speaker \(centroid.rawSpeakerIndex + 1) (\(trueIdentity)): – first occurrence, seeding memory")
                    }
                }

                // After evaluation, "confirm" this speaker into memory (simulating user acceptance)
                let profileID = identityToProfileID[trueIdentity] ?? UUID()
                identityToProfileID[trueIdentity] = profileID
                confirmedCentroids[trueIdentity, default: []].append(
                    (centroid: centroid.centroid, modelVersion: data.modelVersion)
                )
            }
        }

        log("")
        log("== RESULTS ==")
        log("")

        let result = EvaluationResult(
            totalSuggestions: totalSuggestions,
            correctSuggestions: correct,
            incorrectSuggestions: incorrect,
            missedSpeakers: missed
        )

        log("Suggestions made: \(result.totalSuggestions)")
        log("  Correct: \(result.correctSuggestions)")
        log("  Incorrect: \(result.incorrectSuggestions)")
        log("Missed (had memory, no suggestion): \(result.missedSpeakers)")
        log("")
        log("Precision: \(String(format: "%.1f%%", result.precision * 100))")
        log("Recall: \(String(format: "%.1f%%", result.recall * 100))")
        log("")
        log("Phase gate: precision ≥ 95%? \(result.precision >= 0.95 ? "✓ PASS" : "✗ FAIL")")

        return result
    }

    /// Parses "SPEAKER_00" → 0, "Speaker 1" → 0, "Speaker 2" → 1, etc.
    private func parseSpeakerIndex(_ label: String) -> Int? {
        // "SPEAKER_00" format
        if label.hasPrefix("SPEAKER_") {
            return Int(label.replacingOccurrences(of: "SPEAKER_", with: ""))
        }
        // "Speaker 1" format (1-indexed → convert to 0-indexed)
        if label.hasPrefix("Speaker ") {
            if let n = Int(label.replacingOccurrences(of: "Speaker ", with: "")) {
                return n - 1
            }
        }
        return nil
    }
}
