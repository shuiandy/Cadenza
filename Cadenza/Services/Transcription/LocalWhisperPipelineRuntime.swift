import Foundation
import os
import WhisperKit

struct LocalWhisperAudioChunk: Equatable, Sendable {
    let coreStartTime: TimeInterval
    let coreEndTime: TimeInterval
    let loadStartTime: TimeInterval
    let loadEndTime: TimeInterval
    let isFinal: Bool

    func owns(segment: TranscriptionSegment) -> Bool {
        let midpoint = TimeInterval(segment.start + segment.end) / 2
        guard midpoint >= coreStartTime else { return false }
        return isFinal ? midpoint <= coreEndTime : midpoint < coreEndTime
    }
}

enum LocalWhisperChunkPlanner {
    /// A 10-minute 16 kHz Float32 core is about 38.4 MB, bounding the
    /// in-memory audio independently of the recording's total duration.
    static let defaultCoreDuration: TimeInterval = 10 * 60
    /// Load a small amount on both sides of each boundary, then assign each
    /// segment to one core interval and deduplicate near-boundary repeats.
    static let defaultOverlapDuration: TimeInterval = 5

    static func makeChunks(
        duration: TimeInterval,
        coreDuration: TimeInterval = defaultCoreDuration,
        overlapDuration: TimeInterval = defaultOverlapDuration
    ) -> [LocalWhisperAudioChunk] {
        precondition(coreDuration > 0)
        precondition(overlapDuration >= 0)
        guard duration.isFinite, duration > 0 else { return [] }

        let chunkCount = Int(ceil(duration / coreDuration))
        return (0..<chunkCount).map { index in
            let coreStart = TimeInterval(index) * coreDuration
            let coreEnd = min(duration, coreStart + coreDuration)
            return LocalWhisperAudioChunk(
                coreStartTime: coreStart,
                coreEndTime: coreEnd,
                loadStartTime: max(0, coreStart - overlapDuration),
                loadEndTime: min(duration, coreEnd + overlapDuration),
                isFinal: index == chunkCount - 1
            )
        }
    }
}

struct LocalWhisperAudioLoadRequest: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct LocalWhisperPipelineResult: Sendable {
    let segments: [TranscriptionSegment]
    let language: String
    let timings: TranscriptionTimings
}

struct LocalWhisperRuntimeResult: Sendable {
    let segments: [TranscriptionSegment]
    let language: String?
    let timings: TranscriptionTimings?
}

struct LocalWhisperSegmentCandidate: Sendable {
    let segment: TranscriptionSegment
    let chunkIndex: Int
    let normalizedText: String

    init(segment: TranscriptionSegment, chunkIndex: Int) {
        self.segment = segment
        self.chunkIndex = chunkIndex
        normalizedText = segment.text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

struct LocalWhisperDeduplicationResult: Sendable {
    let segments: [TranscriptionSegment]
    /// Counts sorting comparisons, index construction, dictionary lookups, and
    /// Fenwick-tree query/update steps. This makes complexity regressions
    /// observable without relying on wall-clock timing.
    let workUnitCount: Int
}

enum LocalWhisperSegmentDeduplicator {
    static func deduplicate(
        _ candidates: [LocalWhisperSegmentCandidate]
    ) -> LocalWhisperDeduplicationResult {
        var workUnitCount = 0
        let sorted = candidates.sorted {
            workUnitCount += 1
            if $0.segment.start == $1.segment.start {
                if $0.segment.end == $1.segment.end {
                    if $0.chunkIndex == $1.chunkIndex {
                        return $0.segment.id < $1.segment.id
                    }
                    return $0.chunkIndex < $1.chunkIndex
                }
                return $0.segment.end < $1.segment.end
            }
            return $0.segment.start < $1.segment.start
        }

        var durationsByBucket: [LocalWhisperDeduplicationBucketKey: [Float]] = [:]
        durationsByBucket.reserveCapacity(sorted.count)
        for candidate in sorted {
            workUnitCount += 1
            guard Self.canIndex(candidate) else { continue }
            let key = Self.bucketKey(for: candidate)
            durationsByBucket[key, default: []].append(Self.duration(of: candidate))
            workUnitCount += 1
        }

        var buckets: [LocalWhisperDeduplicationBucketKey: LocalWhisperDuplicateBucket] = [:]
        buckets.reserveCapacity(durationsByBucket.count)
        for (key, candidateDurations) in durationsByBucket {
            var durationSortWork = 0
            let sortedDurations = candidateDurations.sorted { lhs, rhs in
                durationSortWork += 1
                return lhs < rhs
            }
            workUnitCount += durationSortWork

            var uniqueDurations: [Float] = []
            uniqueDurations.reserveCapacity(sortedDurations.count)
            for duration in sortedDurations {
                workUnitCount += 1
                if uniqueDurations.last != duration {
                    uniqueDurations.append(duration)
                }
            }

            buckets[key] = LocalWhisperDuplicateBucket(
                sortedUniqueDurations: uniqueDurations
            )
            // Two Fenwick trees plus the dictionary insertion.
            workUnitCount += (uniqueDurations.count + 1) * 2 + 1
        }

        var accepted: [LocalWhisperSegmentCandidate] = []
        accepted.reserveCapacity(sorted.count)

        for candidate in sorted {
            var isDuplicate = false
            if Self.canIndex(candidate) {
                for adjacentChunkIndex in [candidate.chunkIndex - 1, candidate.chunkIndex + 1] {
                    let key = LocalWhisperDeduplicationBucketKey(
                        chunkIndex: adjacentChunkIndex,
                        normalizedText: candidate.normalizedText
                    )
                    workUnitCount += 1
                    guard let bucket = buckets[key] else { continue }
                    let query = bucket.containsDuplicate(of: candidate.segment)
                    workUnitCount += query.workUnitCount
                    if query.isDuplicate {
                        isDuplicate = true
                        break
                    }
                }
            }

            guard !isDuplicate else { continue }
            accepted.append(candidate)
            workUnitCount += 1

            if Self.canIndex(candidate) {
                let key = Self.bucketKey(for: candidate)
                workUnitCount += 1
                if let bucket = buckets[key] {
                    workUnitCount += bucket.insert(candidate.segment)
                }
            }
        }

        let segments = accepted.enumerated().map { index, candidate in
            var segment = candidate.segment
            segment.id = index
            return segment
        }
        workUnitCount += accepted.count
        return LocalWhisperDeduplicationResult(
            segments: segments,
            workUnitCount: workUnitCount
        )
    }

    private static func canIndex(_ candidate: LocalWhisperSegmentCandidate) -> Bool {
        let segment = candidate.segment
        return !candidate.normalizedText.isEmpty
            && segment.start.isFinite
            && segment.end.isFinite
            && segment.end > segment.start
    }

    private static func duration(of candidate: LocalWhisperSegmentCandidate) -> Float {
        candidate.segment.end - candidate.segment.start
    }

    private static func bucketKey(
        for candidate: LocalWhisperSegmentCandidate
    ) -> LocalWhisperDeduplicationBucketKey {
        LocalWhisperDeduplicationBucketKey(
            chunkIndex: candidate.chunkIndex,
            normalizedText: candidate.normalizedText
        )
    }
}

private struct LocalWhisperDeduplicationBucketKey: Hashable {
    let chunkIndex: Int
    let normalizedText: String
}

/// Exact interval-overlap lookup for one `(chunk, normalizedText)` bucket.
///
/// Candidates are inserted in nondecreasing start-time order, so every indexed
/// segment starts no later than the segment being queried.
///
/// For a previous segment with duration `p` and a current segment with duration
/// `d`, the legacy Float-division overlap rule can be answered with two maxima:
///
/// - `p <= d`: the latest current start that still makes the original
///   `(overlap / shorterDuration) >= 0.25` expression true for that previous
///   segment. This boundary is found over Float bit patterns, preserving the
///   old 20 ms time-token rounding behavior exactly.
/// - `p > d`: the maximum previous end; the original division is evaluated
///   directly using the current duration.
///
/// Coordinate-compressed prefix/suffix Fenwick trees provide both queries and
/// insertions in `O(log bucketSize)` without scanning active intervals.
private final class LocalWhisperDuplicateBucket {
    private static let minimumDuration: Float = 0.001
    private static let overlapRatio: Float = 0.25

    private let durations: [Float]
    private var shortDurationLatestStarts: [Float]
    private var longDurationEnds: [Float]

    init(sortedUniqueDurations: [Float]) {
        durations = sortedUniqueDurations
        shortDurationLatestStarts = Array(
            repeating: -.infinity,
            count: sortedUniqueDurations.count + 1
        )
        longDurationEnds = Array(
            repeating: -.infinity,
            count: sortedUniqueDurations.count + 1
        )
    }

    func containsDuplicate(
        of segment: TranscriptionSegment
    ) -> (isDuplicate: Bool, workUnitCount: Int) {
        let duration = segment.end - segment.start
        guard duration.isFinite, duration > 0 else { return (false, 1) }

        let split = upperBound(for: duration)
        var workUnitCount = split.workUnitCount

        let shortMaximum = maximum(
            in: shortDurationLatestStarts,
            through: split.index
        )
        workUnitCount += shortMaximum.workUnitCount
        if shortMaximum.value >= segment.start {
            return (true, workUnitCount)
        }

        let longerDurationCount = durations.count - split.index
        let longMaximum = maximum(
            in: longDurationEnds,
            through: longerDurationCount
        )
        workUnitCount += longMaximum.workUnitCount
        let overlap = min(longMaximum.value, segment.end) - segment.start
        let shorterDuration = max(Self.minimumDuration, duration)
        let isDuplicate = overlap > 0
            && overlap / shorterDuration >= Self.overlapRatio
        return (isDuplicate, workUnitCount + 1)
    }

    func insert(_ segment: TranscriptionSegment) -> Int {
        let duration = segment.end - segment.start
        guard duration.isFinite, duration > 0 else { return 1 }

        let coordinate = lowerBound(for: duration)
        guard coordinate.index < durations.count,
              durations[coordinate.index] == duration else {
            return coordinate.workUnitCount + 1
        }

        let duplicateBoundary = maximumDuplicateStart(for: segment)
        let prefixWork: Int
        if let latestStart = duplicateBoundary.value {
            prefixWork = update(
                tree: &shortDurationLatestStarts,
                at: coordinate.index + 1,
                value: latestStart
            )
        } else {
            prefixWork = 0
        }
        let suffixWork = update(
            tree: &longDurationEnds,
            at: durations.count - coordinate.index,
            value: segment.end
        )
        return coordinate.workUnitCount
            + duplicateBoundary.workUnitCount
            + prefixWork
            + suffixWork
    }

    /// Finds the latest representable Float start time for which the original
    /// division-based duplicate predicate is true. Searching ordered Float bit
    /// patterns is bounded by 32 iterations and avoids changing behavior at
    /// values such as `0.02 / 0.08 == 0.24999996`.
    private func maximumDuplicateStart(
        for segment: TranscriptionSegment
    ) -> (value: Float?, workUnitCount: Int) {
        let duration = segment.end - segment.start
        let shorterDuration = max(Self.minimumDuration, duration)

        func isDuplicate(at currentStart: Float) -> Bool {
            let overlap = segment.end - currentStart
            return overlap > 0
                && overlap / shorterDuration >= Self.overlapRatio
        }

        var workUnitCount = 1
        guard isDuplicate(at: segment.start) else {
            return (nil, workUnitCount)
        }

        var lower = Self.orderedBitPattern(of: segment.start)
        var upper = Self.orderedBitPattern(of: segment.end)
        while upper - lower > 1 {
            workUnitCount += 1
            let middle = lower + (upper - lower) / 2
            if isDuplicate(at: Self.float(fromOrderedBitPattern: middle)) {
                lower = middle
            } else {
                upper = middle
            }
        }
        return (Self.float(fromOrderedBitPattern: lower), workUnitCount)
    }

    private static func orderedBitPattern(of value: Float) -> UInt32 {
        let signMask: UInt32 = 1 << 31
        let bits = value.bitPattern
        return bits & signMask == 0 ? bits | signMask : ~bits
    }

    private static func float(fromOrderedBitPattern ordered: UInt32) -> Float {
        let signMask: UInt32 = 1 << 31
        let bits = ordered & signMask == 0 ? ~ordered : ordered & ~signMask
        return Float(bitPattern: bits)
    }

    private func lowerBound(for value: Float) -> (index: Int, workUnitCount: Int) {
        var lower = 0
        var upper = durations.count
        var workUnitCount = 0
        while lower < upper {
            workUnitCount += 1
            let middle = lower + (upper - lower) / 2
            if durations[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return (lower, workUnitCount)
    }

    private func upperBound(for value: Float) -> (index: Int, workUnitCount: Int) {
        var lower = 0
        var upper = durations.count
        var workUnitCount = 0
        while lower < upper {
            workUnitCount += 1
            let middle = lower + (upper - lower) / 2
            if durations[middle] <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return (lower, workUnitCount)
    }

    private func maximum(
        in tree: [Float],
        through upperBound: Int
    ) -> (value: Float, workUnitCount: Int) {
        var index = upperBound
        var value = -Float.infinity
        var workUnitCount = 0
        while index > 0 {
            workUnitCount += 1
            value = max(value, tree[index])
            index -= index & -index
        }
        return (value, workUnitCount)
    }

    private func update(
        tree: inout [Float],
        at startIndex: Int,
        value: Float
    ) -> Int {
        var index = startIndex
        var workUnitCount = 0
        while index < tree.count {
            workUnitCount += 1
            tree[index] = max(tree[index], value)
            index += index & -index
        }
        return workUnitCount
    }
}

protocol LocalWhisperPipeline: Sendable {
    func transcribe(
        audioArray: [Float],
        options: DecodingOptions,
        progress: (@Sendable (TranscriptionProgress) -> Bool?)?
    ) async throws -> [LocalWhisperPipelineResult]

    func shutdown() async
}

protocol LocalWhisperPipelineFactory: Sendable {
    func makePipeline(
        modelName: String,
        modelFolder: URL
    ) async throws -> any LocalWhisperPipeline
}

protocol LocalWhisperAudioChunkLoading: Sendable {
    func loadAudio(
        at url: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws -> [Float]
}

struct LocalWhisperFileAudioChunkLoader: LocalWhisperAudioChunkLoading {
    func loadAudio(
        at url: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws -> [Float] {
        try Task.checkCancellation()
        let audio = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: url.path,
            startTime: startTime,
            endTime: endTime
        )
        try Task.checkCancellation()
        return audio
    }
}

struct LocalWhisperKitPipelineFactory: LocalWhisperPipelineFactory {
    func makePipeline(
        modelName: String,
        modelFolder: URL
    ) async throws -> any LocalWhisperPipeline {
        NSLog("[LocalWhisper] loading model: %@", modelName)
        let pipeline = try await LocalWhisperKitPipeline.make(
            modelFolderPath: modelFolder.path
        )
        NSLog("[LocalWhisper] model loaded: %@", modelName)
        return pipeline
    }
}

private final class LocalWhisperKitPipeline: LocalWhisperPipeline {
    private enum Command: Sendable {
        case transcribe(
            audioArray: [Float],
            options: DecodingOptions,
            progress: (@Sendable (TranscriptionProgress) -> Bool?)?,
            continuation: CheckedContinuation<[LocalWhisperPipelineResult], Error>
        )
    }

    private let commandContinuation: AsyncStream<Command>.Continuation
    private let workerTask: Task<Void, Never>

    private init(
        commandContinuation: AsyncStream<Command>.Continuation,
        workerTask: Task<Void, Never>
    ) {
        self.commandContinuation = commandContinuation
        self.workerTask = workerTask
    }

    deinit {
        commandContinuation.finish()
        workerTask.cancel()
    }

    static func make(modelFolderPath: String) async throws -> LocalWhisperKitPipeline {
        let (commands, commandContinuation) = AsyncStream.makeStream(of: Command.self)
        let (readiness, readinessContinuation) = AsyncThrowingStream.makeStream(
            of: Void.self,
            throwing: Error.self
        )

        let workerTask = Task.detached(priority: ProcessingWorkPriority.shared.current) {
            do {
                let config = WhisperKitConfig(
                    modelFolder: modelFolderPath,
                    download: false
                )
                let pipeline = try await WhisperKit(config)
                readinessContinuation.yield(())
                readinessContinuation.finish()

                for await command in commands {
                    try Task.checkCancellation()
                    switch command {
                    case let .transcribe(audioArray, options, progress, continuation):
                        do {
                            let rawResults: [TranscriptionResult] = try await pipeline.transcribe(
                                audioArray: audioArray,
                                decodeOptions: options,
                                callback: progress
                            )
                            let results = rawResults.map {
                                LocalWhisperPipelineResult(
                                    segments: $0.segments,
                                    language: $0.language,
                                    timings: $0.timings
                                )
                            }
                            continuation.resume(returning: results)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                readinessContinuation.finish(throwing: error)
            }
        }

        do {
            var readinessIterator = readiness.makeAsyncIterator()
            guard try await readinessIterator.next() != nil else {
                throw TranscriptionError.apiError("Whisper pipeline stopped before loading")
            }
        } catch {
            commandContinuation.finish()
            workerTask.cancel()
            await workerTask.value
            throw error
        }
        return LocalWhisperKitPipeline(
            commandContinuation: commandContinuation,
            workerTask: workerTask
        )
    }

    func transcribe(
        audioArray: [Float],
        options: DecodingOptions,
        progress: (@Sendable (TranscriptionProgress) -> Bool?)?
    ) async throws -> [LocalWhisperPipelineResult] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let yieldResult = commandContinuation.yield(
                .transcribe(
                    audioArray: audioArray,
                    options: options,
                    progress: progress,
                    continuation: continuation
                )
            )
            if case .terminated = yieldResult {
                continuation.resume(
                    throwing: TranscriptionError.apiError("Whisper pipeline is unavailable")
                )
            }
        }
    }

    func shutdown() async {
        commandContinuation.finish()
        await workerTask.value
    }
}

actor LocalWhisperPipelineRuntime {
    private struct CacheKey: Equatable {
        let modelName: String
        let modelFolderPath: String
    }

    private let factory: any LocalWhisperPipelineFactory
    private let audioLoader: any LocalWhisperAudioChunkLoading
    private let coreChunkDuration: TimeInterval
    private let overlapDuration: TimeInterval
    private let accessPool = AsyncPermitPool(limit: 1)

    private var cachedKey: CacheKey?
    private var cachedPipeline: (any LocalWhisperPipeline)?

#if DEBUG
    var waitingOperationCountForTesting: Int {
        get async {
            await accessPool.waitingCountForTesting
        }
    }
#endif

    init(
        factory: any LocalWhisperPipelineFactory = LocalWhisperKitPipelineFactory(),
        audioLoader: any LocalWhisperAudioChunkLoading = LocalWhisperFileAudioChunkLoader(),
        coreChunkDuration: TimeInterval = LocalWhisperChunkPlanner.defaultCoreDuration,
        overlapDuration: TimeInterval = LocalWhisperChunkPlanner.defaultOverlapDuration
    ) {
        self.factory = factory
        self.audioLoader = audioLoader
        self.coreChunkDuration = coreChunkDuration
        self.overlapDuration = overlapDuration
    }

    func transcribe(
        modelName: String,
        modelFolder: URL,
        audioURL: URL,
        duration: TimeInterval,
        options: DecodingOptions,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> LocalWhisperRuntimeResult {
        let cancellation = LocalWhisperCancellationState()
        return try await withTaskCancellationHandler {
            try await accessPool.withPermit { [self] in
                try await transcribeWithExclusiveAccess(
                    modelName: modelName,
                    modelFolder: modelFolder,
                    audioURL: audioURL,
                    duration: duration,
                    options: options,
                    onProgress: onProgress,
                    cancellation: cancellation
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Waits for active inference to finish, then clears the cache at a
    /// linearization point protected by the same exclusive permit.
    func releasePipeline() async throws {
        try await withReleasedPipeline {}
    }

    /// Clears the cached CoreML graph and performs a dependent mutation while
    /// holding the same exclusive permit. A queued transcription cannot reload
    /// the model between the release and filesystem mutation.
    func withReleasedPipeline<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await accessPool.withPermit { [self] in
            await clearCachedPipeline()
            try Task.checkCancellation()
            return try await operation()
        }
    }

    private func clearCachedPipeline() async {
        if let cachedPipeline {
            await cachedPipeline.shutdown()
        }
        cachedPipeline = nil
        cachedKey = nil
        NSLog("[LocalWhisper] pipeline released")
    }

    private func transcribeWithExclusiveAccess(
        modelName: String,
        modelFolder: URL,
        audioURL: URL,
        duration: TimeInterval,
        options: DecodingOptions,
        onProgress: (@Sendable (Int, Int) -> Void)?,
        cancellation: LocalWhisperCancellationState
    ) async throws -> LocalWhisperRuntimeResult {
        try Task.checkCancellation()
        let chunks = LocalWhisperChunkPlanner.makeChunks(
            duration: duration,
            coreDuration: coreChunkDuration,
            overlapDuration: overlapDuration
        )
        guard !chunks.isEmpty else {
            return LocalWhisperRuntimeResult(segments: [], language: options.language, timings: nil)
        }

        let pipeline = try await pipeline(for: modelName, modelFolder: modelFolder)
        let estimatedWindows = max(1, Int(ceil(duration / 30)))
        let progressReporter = LocalWhisperProgressReporter(
            total: estimatedWindows,
            callback: onProgress
        )

        var candidates: [LocalWhisperSegmentCandidate] = []
        var detectedLanguage: String?
        var firstTimings: TranscriptionTimings?

        for (chunkIndex, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let audioArray = try await audioLoader.loadAudio(
                at: audioURL,
                startTime: chunk.loadStartTime,
                endTime: chunk.loadEndTime
            )
            try Task.checkCancellation()

            let completedBeforeChunk = Int(floor(chunk.coreStartTime / 30))
            let coreWindowCount = max(1, Int(ceil((chunk.coreEndTime - chunk.coreStartTime) / 30)))
            let callback: @Sendable (TranscriptionProgress) -> Bool? = { progress in
                let localDone = min(coreWindowCount, progress.windowId + 1)
                progressReporter.report(completedBeforeChunk + localDone)
                return !cancellation.isCancelled
            }

            let chunkResults = try await pipeline.transcribe(
                audioArray: audioArray,
                options: options,
                progress: callback
            )
            try Task.checkCancellation()

            for result in chunkResults {
                if detectedLanguage == nil, !result.language.isEmpty {
                    detectedLanguage = result.language
                }
                if firstTimings == nil {
                    firstTimings = result.timings
                }

                for segment in result.segments {
                    let adjusted = TranscriptionUtilities.updateSegmentTimings(
                        segment: segment,
                        seekTime: Float(chunk.loadStartTime)
                    )
                    if chunk.owns(segment: adjusted) {
                        candidates.append(
                            LocalWhisperSegmentCandidate(
                                segment: adjusted,
                                chunkIndex: chunkIndex
                            )
                        )
                    }
                }
            }

            let completedCoreWindows = Int(ceil(chunk.coreEndTime / 30))
            progressReporter.report(completedCoreWindows)
        }

        let segments = LocalWhisperSegmentDeduplicator
            .deduplicate(candidates)
            .segments
        return LocalWhisperRuntimeResult(
            segments: segments,
            language: detectedLanguage ?? options.language,
            timings: firstTimings
        )
    }

    private func pipeline(
        for modelName: String,
        modelFolder: URL
    ) async throws -> any LocalWhisperPipeline {
        let key = CacheKey(
            modelName: modelName,
            modelFolderPath: modelFolder.standardizedFileURL.path
        )
        if cachedKey == key, let cachedPipeline {
            return cachedPipeline
        }

        // Drop the previous CoreML graph before loading another model so a
        // model switch cannot temporarily retain both large pipelines.
        if let cachedPipeline {
            await cachedPipeline.shutdown()
        }
        cachedPipeline = nil
        cachedKey = nil
        let pipeline = try await factory.makePipeline(
            modelName: modelName,
            modelFolder: modelFolder
        )
        cachedKey = key
        cachedPipeline = pipeline
        return pipeline
    }

}

private final class LocalWhisperCancellationState: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        lock.withLock { $0 }
    }

    func cancel() {
        lock.withLock { $0 = true }
    }
}

private final class LocalWhisperProgressReporter: Sendable {
    private struct State {
        var highWaterMark = 0
    }

    private let total: Int
    private let callback: (@Sendable (Int, Int) -> Void)?
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(total: Int, callback: (@Sendable (Int, Int) -> Void)?) {
        self.total = total
        self.callback = callback
    }

    func report(_ completed: Int) {
        guard let callback else { return }
        lock.withLock { state in
            let bounded = min(max(0, completed), total)
            guard bounded > state.highWaterMark else { return }
            state.highWaterMark = bounded
            callback(bounded, total)
        }
    }
}
