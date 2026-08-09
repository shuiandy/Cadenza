import Foundation

// MARK: - Configuration

struct SpeakerMemoryConfig: Sendable {
    let minimumSpeechSeconds: Float
    let minimumNonOverlapRatio: Float
    let topScoreThresholdMultiSample: Float
    let topScoreThresholdSingleSample: Float
    let autoApplyThreshold: Float
    let runnerUpMargin: Float

    static let `default` = SpeakerMemoryConfig(
        minimumSpeechSeconds: 15,
        minimumNonOverlapRatio: 0.6,
        topScoreThresholdMultiSample: 0.50,
        topScoreThresholdSingleSample: 0.60,
        autoApplyThreshold: 0.75,
        runnerUpMargin: 0.05
    )
}

struct SpeakerLabelSpan: Sendable {
    let label: String
    let startTime: Float
    let endTime: Float

    init?(label: String?, startTime: TimeInterval, endTime: TimeInterval) {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty,
              endTime > startTime else { return nil }
        self.label = label
        self.startTime = Float(startTime)
        self.endTime = Float(endTime)
    }

    init(label: String, startTime: Float, endTime: Float) {
        self.label = label
        self.startTime = startTime
        self.endTime = endTime
    }

    static func fromTranscriptEntries(_ entries: [TranscriptEntry]) -> [SpeakerLabelSpan] {
        entries.compactMap { entry in
            SpeakerLabelSpan(label: entry.speaker, startTime: entry.startTime, endTime: entry.endTime)
        }
    }

    static func fromSpeakerLabels(_ labels: [String]) -> [SpeakerLabelSpan] {
        labels.enumerated().map { idx, label in
            SpeakerLabelSpan(label: label, startTime: Float(idx), endTime: Float(idx + 1))
        }
    }
}

// MARK: - Match Result

struct SpeakerMatchResult: Sendable {
    let profileID: UUID
    let score: Float
    let runnerUpScore: Float?
}

// MARK: - SpeakerMemoryService

final class SpeakerMemoryService: Sendable {
    let config: SpeakerMemoryConfig

    init(config: SpeakerMemoryConfig = .default) {
        self.config = config
    }

    // MARK: - Public types

    struct ProfileSample: Sendable {
        let profileID: UUID
        let centroid: [Float]
        let modelVersion: String
        let sampleCount: Int
    }

    struct SpeakerCentroidResult: Sendable {
        let rawSpeakerIndex: Int
        let centroid: [Float]
        let windowCount: Int
        let totalSpeechSeconds: Float
        let averageNonOverlapRatio: Float
    }

    // MARK: - Quality gating

    func filterWindows(
        _ windows: [SpeakerWindowEmbedding],
        minimumNonOverlapRatio: Float
    ) -> [SpeakerWindowEmbedding] {
        windows.filter { $0.nonOverlapRatio >= minimumNonOverlapRatio }
    }

    // MARK: - Centroid construction

    /// Groups windows by speaker, filters by quality, computes centroids.
    /// Returns one centroid per speaker that passes all gates.
    func buildCentroids(
        from result: SpeakerEmbeddingResult
    ) -> [SpeakerCentroidResult] {
        let grouped = Dictionary(grouping: result.embeddings, by: \.rawSpeakerIndex)
        var centroids: [SpeakerCentroidResult] = []

        for (speakerIndex, windows) in grouped {
            let accepted = filterWindows(windows, minimumNonOverlapRatio: config.minimumNonOverlapRatio)
            guard !accepted.isEmpty else { continue }

            // Estimate speech from sliding-window stride, not raw 10s window width.
            let totalSpeech = Self.estimateSpeechSeconds(from: accepted)
            guard totalSpeech >= config.minimumSpeechSeconds else { continue }
            let avgNonOverlap = accepted.reduce(Float(0)) { $0 + $1.nonOverlapRatio } / Float(accepted.count)

            // L2-normalize each window, then compute centroid (mean of normalized vectors)
            let normalized = accepted.map { Self.l2Normalize($0.embedding) }
            let centroid = Self.computeCentroid(normalized)

            centroids.append(SpeakerCentroidResult(
                rawSpeakerIndex: speakerIndex,
                centroid: centroid,
                windowCount: accepted.count,
                totalSpeechSeconds: totalSpeech,
                averageNonOverlapRatio: avgNonOverlap
            ))
        }

        return centroids
    }

    // MARK: - Matching

    func matchSpeaker(
        centroid: [Float],
        confirmedSamples: [ProfileSample],
        currentModelVersion: String
    ) -> SpeakerMatchResult? {
        // Filter to matching model version and embedding dimension.
        // SpeakerKit changed embedding dimensions across local model/cache revisions
        // while the app-level modelVersion string stayed stable. Mixing those
        // vectors makes cosine matching useless and can collapse speaker memory.
        let eligible = confirmedSamples.filter {
            $0.modelVersion == currentModelVersion && $0.centroid.count == centroid.count
        }
        guard !eligible.isEmpty else { return nil }

        // Score each profile
        let normalizedCentroid = Self.l2Normalize(centroid)
        var scores: [(profileID: UUID, score: Float, sampleCount: Int)] = []

        for sample in eligible {
            let score = Self.cosineSimilarity(normalizedCentroid, Self.l2Normalize(sample.centroid))
            scores.append((sample.profileID, score, sample.sampleCount))
        }

        // Sort descending by score
        scores.sort { $0.score > $1.score }

        guard let top = scores.first else { return nil }

        // Choose threshold based on sample count
        let threshold = top.sampleCount >= 2
            ? config.topScoreThresholdMultiSample
            : config.topScoreThresholdSingleSample

        let runnerUpScore = scores.count >= 2 ? scores[1].score : nil
        let margin = runnerUpScore.map { top.score - $0 }

        NSLog("[SpeakerMemory] Match: top=%.3f (threshold=%.3f, samples=%d), runner=%.3f, margin=%.3f",
              top.score, threshold, top.sampleCount,
              runnerUpScore ?? -1, margin ?? 999)

        guard top.score >= threshold else {
            NSLog("[SpeakerMemory] REJECTED: score %.3f < threshold %.3f", top.score, threshold)
            return nil
        }

        if let m = margin, m < config.runnerUpMargin {
            NSLog("[SpeakerMemory] REJECTED: margin %.3f < required %.3f", m, config.runnerUpMargin)
            return nil
        }

        return SpeakerMatchResult(
            profileID: top.profileID,
            score: top.score,
            runnerUpScore: runnerUpScore
        )
    }

    // MARK: - Vector Math (static for testability)

    static func l2Normalize(_ v: [Float]) -> [Float] {
        let magnitude = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return v }
        return v.map { $0 / magnitude }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return dot
    }

    static func computeCentroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for v in vectors {
            for i in 0..<dim {
                sum[i] += v[i]
            }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }

    static func estimateSpeechSeconds(from windows: [SpeakerWindowEmbedding]) -> Float {
        let sorted = windows.sorted { ($0.windowStart, $0.windowEnd) < ($1.windowStart, $1.windowEnd) }
        guard !sorted.isEmpty else { return 0 }

        let windowDuration: Float = 10.0
        let positiveDeltas = zip(sorted, sorted.dropFirst())
            .map { $1.windowStart - $0.windowStart }
            .filter { $0 > 0 && $0 <= windowDuration }
            .sorted()

        let terminalStep: Float
        if positiveDeltas.isEmpty {
            terminalStep = windowDuration
        } else {
            terminalStep = positiveDeltas[positiveDeltas.count / 2]
        }

        var total: Float = 0
        for idx in sorted.indices {
            let coverage: Float
            if idx < sorted.index(before: sorted.endIndex) {
                let nextStart = sorted[sorted.index(after: idx)].windowStart
                let delta = nextStart - sorted[idx].windowStart
                coverage = delta > 0 ? min(delta, windowDuration) : terminalStep
            } else {
                coverage = terminalStep
            }
            total += coverage * sorted[idx].nonOverlapRatio
        }
        return total
    }

    // MARK: - Speaker Index to Label Mapping

    /// Maps diarization cluster IDs to transcript speaker labels using temporal overlap.
    ///
    /// Scores exact recording-wide speaker activity spans against timestamped transcript
    /// spans, then chooses a one-to-one mapping that maximizes total temporal overlap.
    /// Embedding windows are intentionally not used here: each one is 10 seconds wide
    /// and can contain turns from both people even when its centroid belongs to one.
    ///
    func buildSpeakerIndexToLabelMapping(
        centroids: [SpeakerCentroidResult],
        speakerActivitySpans: [SpeakerAssignmentSpan],
        speakerSpans: [SpeakerLabelSpan]
    ) -> [Int: String] {
        let validSpans = speakerSpans.filter {
            $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime
        }
        guard !validSpans.isEmpty else { return [:] }

        let centroidIDs = Set(centroids.map(\.rawSpeakerIndex))
        let acceptedActivity = speakerActivitySpans.filter {
            centroidIDs.contains($0.speakerID)
                && $0.startTime.isFinite
                && $0.endTime.isFinite
                && $0.endTime > $0.startTime
        }
        let activityBySpeaker = Dictionary(grouping: acceptedActivity, by: \.speakerID)

        var labelSpans: [String: [SpeakerLabelSpan]] = [:]
        for span in validSpans {
            labelSpans[span.label, default: []].append(span)
        }

        let orderedSpeakerIDs = centroidIDs.sorted {
            let lhsStart = activityBySpeaker[$0]?.map(\.startTime).min() ?? .greatestFiniteMagnitude
            let rhsStart = activityBySpeaker[$1]?.map(\.startTime).min() ?? .greatestFiniteMagnitude
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return $0 < $1
        }
        let orderedLabels = labelSpans.keys.sorted()
        var scores: [Int: [String: Float]] = [:]
        var activityDurations: [Int: Float] = [:]

        for speakerID in orderedSpeakerIDs {
            activityDurations[speakerID] = (activityBySpeaker[speakerID] ?? []).reduce(0) {
                $0 + Float($1.endTime - $1.startTime)
            }
            for label in orderedLabels {
                var weightedOverlap: Float = 0
                for activity in activityBySpeaker[speakerID] ?? [] {
                    for span in labelSpans[label] ?? [] {
                        let overlapStart = max(Float(activity.startTime), span.startTime)
                        let overlapEnd = min(Float(activity.endTime), span.endTime)
                        if overlapEnd > overlapStart {
                            weightedOverlap += overlapEnd - overlapStart
                        }
                    }
                }
                scores[speakerID, default: [:]][label] = weightedOverlap
            }
        }

        // A tiny boundary overlap or an even split is not identity evidence.
        // Only the dominant label for a cluster can enter the global assignment;
        // ambiguous/under-covered clusters remain deliberately unmatched so they
        // cannot poison persisted voice samples.
        var confidentScores: [Int: [String: Float]] = [:]
        for speakerID in orderedSpeakerIDs {
            let ranked = orderedLabels.map { label in
                (label: label, score: scores[speakerID]?[label] ?? 0)
            }.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.label < $1.label
            }
            guard let top = ranked.first else { continue }
            let totalActivity = activityDurations[speakerID] ?? 0
            let totalLabeledOverlap = ranked.reduce(Float(0)) { $0 + $1.score }
            let runnerUp = ranked.dropFirst().first?.score ?? 0
            let coverage = totalActivity > 0
                ? min(totalLabeledOverlap, totalActivity) / totalActivity
                : 0
            let dominance = totalLabeledOverlap > 0 ? top.score / totalLabeledOverlap : 0
            let margin = top.score - runnerUp
            let minimumMargin = max(Float(1), top.score * 0.10)

            guard top.score >= 1,
                  coverage >= 0.50,
                  dominance >= 0.60,
                  margin >= minimumMargin else {
                NSLog(
                    "[SpeakerMemory] Unmatched cluster %d: overlap=%.2f coverage=%.2f dominance=%.2f margin=%.2f",
                    speakerID,
                    top.score,
                    coverage,
                    dominance,
                    margin
                )
                continue
            }
            confidentScores[speakerID] = [top.label: top.score]
        }

        return Self.maximumWeightMapping(
            speakerIDs: orderedSpeakerIDs,
            labels: orderedLabels,
            scores: confidentScores
        )
    }

    /// Maximum-weight one-to-one assignment with one private dummy column per
    /// speaker, so any cluster can remain unmatched. This is the rectangular
    /// Hungarian algorithm and has deterministic O(n³) behavior for large calls.
    static func maximumWeightMapping(
        speakerIDs: [Int],
        labels: [String],
        scores: [Int: [String: Float]]
    ) -> [Int: String] {
        guard !speakerIDs.isEmpty, !labels.isEmpty else { return [:] }
        let rowCount = speakerIDs.count
        let realColumnCount = labels.count
        let columnCount = realColumnCount + rowCount
        var rowPotential = [Double](repeating: 0, count: rowCount + 1)
        var columnPotential = [Double](repeating: 0, count: columnCount + 1)
        var matchedRow = [Int](repeating: 0, count: columnCount + 1)
        var predecessor = [Int](repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            matchedRow[0] = row
            var currentColumn = 0
            var minimumReducedCost = [Double](repeating: .infinity, count: columnCount + 1)
            var visited = [Bool](repeating: false, count: columnCount + 1)

            repeat {
                visited[currentColumn] = true
                let currentRow = matchedRow[currentColumn]
                var delta = Double.infinity
                var nextColumn = 0

                for column in 1...columnCount where !visited[column] {
                    let weight: Double
                    if column <= realColumnCount {
                        weight = Double(scores[speakerIDs[currentRow - 1]]?[labels[column - 1]] ?? 0)
                    } else {
                        weight = 0
                    }
                    let reducedCost = -weight - rowPotential[currentRow] - columnPotential[column]
                    if reducedCost < minimumReducedCost[column] {
                        minimumReducedCost[column] = reducedCost
                        predecessor[column] = currentColumn
                    }
                    if minimumReducedCost[column] < delta
                        || (minimumReducedCost[column] == delta && column < nextColumn) {
                        delta = minimumReducedCost[column]
                        nextColumn = column
                    }
                }

                for column in 0...columnCount {
                    if visited[column] {
                        rowPotential[matchedRow[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minimumReducedCost[column] -= delta
                    }
                }
                currentColumn = nextColumn
            } while matchedRow[currentColumn] != 0

            repeat {
                let previousColumn = predecessor[currentColumn]
                matchedRow[currentColumn] = matchedRow[previousColumn]
                currentColumn = previousColumn
            } while currentColumn != 0
        }

        var mapping: [Int: String] = [:]
        for column in 1...realColumnCount {
            let row = matchedRow[column]
            guard row > 0 else { continue }
            let speakerID = speakerIDs[row - 1]
            let label = labels[column - 1]
            guard (scores[speakerID]?[label] ?? 0) > 0 else { continue }
            mapping[speakerID] = label
        }
        return mapping
    }

    // MARK: - Full Analysis Pipeline

    /// Runs the complete speaker memory pipeline for one recording.
    /// Called from PostProcessingCoordinator as a detached utility task.
    func analyze(
        recordingID: UUID,
        audioURL: URL,
        speakerLabels: [String],
        speakerIdentityRevision: UInt64,
        store: RecordingsStore,
        extractor: SpeakerEmbeddingExtractorProtocol = SpeakerKitEmbeddingExtractor()
    ) async throws {
        try await analyze(
            recordingID: recordingID,
            audioURL: audioURL,
            speakerSpans: SpeakerLabelSpan.fromSpeakerLabels(speakerLabels),
            speakerIdentityRevision: speakerIdentityRevision,
            store: store,
            extractor: extractor
        )
    }

    func analyze(
        recordingID: UUID,
        audioURL: URL,
        speakerSpans: [SpeakerLabelSpan],
        speakerIdentityRevision: UInt64,
        store: RecordingsStore,
        extractor: SpeakerEmbeddingExtractorProtocol = SpeakerKitEmbeddingExtractor()
    ) async throws {
        NSLog("[SpeakerMemory] Starting analysis for recording %@", recordingID.uuidString)
        guard await store.isSpeakerIdentityRevisionCurrent(
            recordingID: recordingID,
            revision: speakerIdentityRevision
        ) else {
            NSLog("[SpeakerMemory] Skipping stale analysis for %@", recordingID.uuidString)
            return
        }

        guard let speakerMemorySession = await store.beginSpeakerMemoryWriteSession() else {
            NSLog("[SpeakerMemory] Cross-recording voice memory is disabled")
            return
        }

        // Step 1: Extract embeddings
        let result = try await extractor.extractEmbeddings(from: audioURL)
        try Task.checkCancellation()
        guard await store.isSpeakerIdentityRevisionCurrent(
            recordingID: recordingID,
            revision: speakerIdentityRevision
        ) else {
            NSLog("[SpeakerMemory] Discarding stale analysis for %@", recordingID.uuidString)
            return
        }
        guard !result.embeddings.isEmpty else {
            NSLog("[SpeakerMemory] No embeddings extracted, skipping")
            return
        }

        // Step 2: Build centroids first (needed for label mapping)
        let centroids = buildCentroids(from: result)
        guard !centroids.isEmpty else {
            NSLog("[SpeakerMemory] No centroids passed quality gates")
            return
        }

        // Step 2.5: Build speaker index → label mapping using temporal overlap.
        // Diarization is non-deterministic: cluster IDs differ between runs, and
        // quality gating may filter speakers. Match each centroid to the transcript
        // label that overlaps most with its windows, not by positional order.
        let indexToLabel = buildSpeakerIndexToLabelMapping(
            centroids: centroids,
            speakerActivitySpans: result.speakerActivitySpans,
            speakerSpans: speakerSpans
        )
        NSLog("[SpeakerMemory] indexToLabel: %@", indexToLabel.map { "\($0.key)→\($0.value)" }.joined(separator: ", "))

        // Step 4: Build and persist every sample in one transaction. Saving
        // centroids one at a time could leave a partial recording that future
        // analyses mistake for a completed speaker-memory pass.
        var sampleWrites: [RecordingsStore.VoiceSampleWrite] = []
        for centroid in centroids {
            try Task.checkCancellation()
            guard let rawLabel = indexToLabel[centroid.rawSpeakerIndex] else {
                NSLog("[SpeakerMemory] Skipping centroid index %d — not in indexToLabel", centroid.rawSpeakerIndex)
                continue
            }
            let normalizedCentroid = Self.l2Normalize(centroid.centroid)
            let embeddingData = SpeakerVoiceSample.serializeEmbedding(normalizedCentroid)
            let qualityScore = centroid.totalSpeechSeconds * Float(centroid.windowCount) / 100.0

            sampleWrites.append(RecordingsStore.VoiceSampleWrite(
                rawLabel: rawLabel,
                embeddingData: embeddingData,
                embeddingDimension: result.embeddingDimension,
                sampleDuration: TimeInterval(centroid.totalSpeechSeconds),
                nonOverlapRatio: centroid.averageNonOverlapRatio,
                qualityScore: qualityScore,
                modelVersion: extractor.modelVersion
            ))
        }

        let sampleWriteResult = await store.upsertVoiceSamplesIfCurrent(
            recordingID: recordingID,
            samples: sampleWrites,
            expectedSpeakerIdentityRevision: speakerIdentityRevision,
            speakerMemorySession: speakerMemorySession
        )
        guard sampleWriteResult == .applied else {
            NSLog(
                "[SpeakerMemory] Stopping after voice sample batch result: %@",
                String(describing: sampleWriteResult)
            )
            return
        }

        // Step 5: Match against confirmed profiles
        // fetchConfirmedSamples returns value types (extracted on the store actor)
        // to avoid cross-actor SwiftData model access
        let confirmedSamples = await store.fetchConfirmedSamples(
            modelVersion: extractor.modelVersion,
            embeddingDimension: result.embeddingDimension
        )
        guard !confirmedSamples.isEmpty else {
            NSLog("[SpeakerMemory] No confirmed samples, skipping matching")
            return
        }

        let matchInputs = confirmedSamples.map { sample in
            ProfileSample(
                profileID: sample.profileID,
                centroid: sample.embedding,
                modelVersion: sample.modelVersion,
                sampleCount: sample.sampleCount
            )
        }

        NSLog("[SpeakerMemory] Step 6: %d confirmed profiles, %d centroids, indexToLabel=%@",
              matchInputs.count, centroids.count,
              indexToLabel.map { "\($0.key)→\($0.value)" }.joined(separator: ","))

        // Step 6: Generate suggestions and auto-apply high-confidence matches
        var suggestions: [SpeakerLabelSuggestion] = []
        var autoApplied = 0
        for centroid in centroids {
            try Task.checkCancellation()
            guard let rawLabel = indexToLabel[centroid.rawSpeakerIndex] else {
                NSLog("[SpeakerMemory] Skipping centroid index %d — not in indexToLabel", centroid.rawSpeakerIndex)
                continue
            }
            let normalizedCentroid = Self.l2Normalize(centroid.centroid)

            if let match = matchSpeaker(
                centroid: normalizedCentroid,
                confirmedSamples: matchInputs,
                currentModelVersion: extractor.modelVersion
            ) {
                if match.score >= config.autoApplyThreshold {
                    // High confidence: auto-apply mapping
                    let mappingResult = await store.applySpeakerMappingIfCurrent(
                        recordingID: recordingID,
                        rawLabel: rawLabel,
                        profileID: match.profileID,
                        expectedSpeakerIdentityRevision: speakerIdentityRevision,
                        speakerMemorySession: speakerMemorySession
                    )
                    if mappingResult == .preservedExistingMapping {
                        NSLog("[SpeakerMemory] Preserved user mapping for %@", rawLabel)
                        continue
                    }
                    guard mappingResult == .applied else {
                        NSLog(
                            "[SpeakerMemory] Stopping after automatic mapping result: %@",
                            String(describing: mappingResult)
                        )
                        return
                    }
                    autoApplied += 1
                    NSLog("[SpeakerMemory] Auto-applied: %@ → profile (score=%.3f)", rawLabel, match.score)
                } else {
                    // Medium confidence: save as suggestion
                    suggestions.append(SpeakerLabelSuggestion(
                        rawLabel: rawLabel,
                        profileID: match.profileID,
                        score: match.score,
                        strategy: "voice",
                        modelVersion: extractor.modelVersion,
                        generatedAt: Date()
                    ))
                }
            }
        }

        // Step 7: Persist suggestions
        let saved = await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: suggestions,
            expectedSpeakerIdentityRevision: speakerIdentityRevision,
            speakerMemorySession: speakerMemorySession
        )
        guard saved else {
            NSLog("[SpeakerMemory] Discarding stale or unsaved suggestions")
            return
        }
        NSLog("[SpeakerMemory] Analysis complete: %d samples, %d auto-applied, %d suggestions", sampleWrites.count, autoApplied, suggestions.count)
    }
}
