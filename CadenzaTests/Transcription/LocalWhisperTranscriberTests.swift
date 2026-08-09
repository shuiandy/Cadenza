import Foundation
import os
import Testing
import WhisperKit

@testable import Cadenza

@Suite("Local Whisper runtime")
struct LocalWhisperTranscriberTests {
    @Test func chunkPlanBoundsMemoryAndOverlapsEveryInteriorBoundary() throws {
        let chunks = LocalWhisperChunkPlanner.makeChunks(
            duration: 3_601,
            coreDuration: 600,
            overlapDuration: 5
        )

        #expect(chunks.count == 7)
        #expect(chunks.first?.coreStartTime == 0)
        #expect(chunks.last?.coreEndTime == 3_601)
        #expect(chunks.allSatisfy { $0.coreEndTime - $0.coreStartTime <= 600 })
        #expect(chunks.allSatisfy { $0.loadEndTime - $0.loadStartTime <= 610 })

        for index in 1..<chunks.count {
            let previous = chunks[index - 1]
            let current = chunks[index]
            #expect(previous.coreEndTime == current.coreStartTime)
            #expect(previous.loadEndTime > current.loadStartTime)
            #expect(previous.loadEndTime - current.loadStartTime <= 10)
        }
    }

    @Test func concurrentSameModelRequestsLoadOnceAndNeverSharePipeline() async throws {
        let gate = LocalWhisperTestGate()
        let probe = LocalWhisperPipelineProbe()
        let factory = LocalWhisperFakePipelineFactory(gate: gate, probe: probe)
        let loader = LocalWhisperFakeAudioLoader()
        let runtime = LocalWhisperPipelineRuntime(
            factory: factory,
            audioLoader: loader,
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        let first = Task {
            try await runtime.transcribe(
                modelName: "base",
                modelFolder: URL(fileURLWithPath: "/models/base"),
                audioURL: URL(fileURLWithPath: "/tmp/first.wav"),
                duration: 1,
                options: DecodingOptions()
            )
        }
        let second = Task {
            try await runtime.transcribe(
                modelName: "base",
                modelFolder: URL(fileURLWithPath: "/models/base"),
                audioURL: URL(fileURLWithPath: "/tmp/second.wav"),
                duration: 1,
                options: DecodingOptions()
            )
        }

        #expect(await waitUntil { await probe.activeCount == 1 })
        #expect(await factory.loadCount == 1)
        await gate.open()
        _ = try await first.value
        _ = try await second.value

        #expect(await factory.loadCount == 1)
        #expect(await probe.maximumActiveCount == 1)
        #expect(await probe.completedCount == 2)
    }

    @Test func stressManyConcurrentRequestsRemainSingleFlight() async throws {
        let probe = LocalWhisperPipelineProbe()
        let factory = LocalWhisperFakePipelineFactory(probe: probe)
        let runtime = LocalWhisperPipelineRuntime(
            factory: factory,
            audioLoader: LocalWhisperFakeAudioLoader(),
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        let tasks = (0..<32).map { index in
            Task {
                try await runtime.transcribe(
                    modelName: "base",
                    modelFolder: URL(fileURLWithPath: "/models/base"),
                    audioURL: URL(fileURLWithPath: "/tmp/stress-\(index).wav"),
                    duration: 1,
                    options: DecodingOptions()
                )
            }
        }
        for task in tasks {
            _ = try await task.value
        }

        #expect(await factory.loadCount == 1)
        #expect(await probe.maximumActiveCount == 1)
        #expect(await probe.completedCount == 32)
    }

    @Test func differentModelsSwitchSeriallyWithoutOverlappingLoadsOrInference() async throws {
        let probe = LocalWhisperPipelineProbe()
        let factory = LocalWhisperFakePipelineFactory(probe: probe)
        let runtime = LocalWhisperPipelineRuntime(
            factory: factory,
            audioLoader: LocalWhisperFakeAudioLoader(),
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        async let base = runtime.transcribe(
            modelName: "base",
            modelFolder: URL(fileURLWithPath: "/models/base"),
            audioURL: URL(fileURLWithPath: "/tmp/base.wav"),
            duration: 1,
            options: DecodingOptions()
        )
        async let small = runtime.transcribe(
            modelName: "small",
            modelFolder: URL(fileURLWithPath: "/models/small"),
            audioURL: URL(fileURLWithPath: "/tmp/small.wav"),
            duration: 1,
            options: DecodingOptions()
        )
        _ = try await (base, small)

        #expect(await factory.loadCount == 2)
        #expect(await factory.maximumActiveLoadCount == 1)
        #expect(await probe.maximumActiveCount == 1)
        #expect(await probe.maximumResidentPipelineCount == 1)
    }

    @Test func releaseLinearizesAfterActiveInferenceAndForcesNextReload() async throws {
        let gate = LocalWhisperTestGate()
        let probe = LocalWhisperPipelineProbe()
        let releaseProbe = LocalWhisperReleaseProbe()
        let factory = LocalWhisperFakePipelineFactory(gate: gate, probe: probe)
        let runtime = LocalWhisperPipelineRuntime(
            factory: factory,
            audioLoader: LocalWhisperFakeAudioLoader(),
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        let transcription = Task {
            try await runtime.transcribe(
                modelName: "base",
                modelFolder: URL(fileURLWithPath: "/models/base"),
                audioURL: URL(fileURLWithPath: "/tmp/active.wav"),
                duration: 1,
                options: DecodingOptions()
            )
        }
        #expect(await waitUntil { await probe.activeCount == 1 })

        let release = Task {
            try await runtime.releasePipeline()
            await releaseProbe.markReturned()
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(await releaseProbe.returned == false)

        await gate.open()
        _ = try await transcription.value
        try await release.value
        #expect(await releaseProbe.returned)

        _ = try await runtime.transcribe(
            modelName: "base",
            modelFolder: URL(fileURLWithPath: "/models/base"),
            audioURL: URL(fileURLWithPath: "/tmp/after-release.wav"),
            duration: 1,
            options: DecodingOptions()
        )
        #expect(await factory.loadCount == 2)
    }

    @Test func modelDeletionHoldsExclusiveAccessAgainstQueuedTranscription() async throws {
        let inferenceGate = LocalWhisperTestGate()
        let deletionGate = LocalWhisperTestGate()
        let pipelineProbe = LocalWhisperPipelineProbe()
        let deletionProbe = LocalWhisperDeletionProbe()
        let factory = LocalWhisperFakePipelineFactory(
            gate: inferenceGate,
            probe: pipelineProbe
        )
        let runtime = LocalWhisperPipelineRuntime(
            factory: factory,
            audioLoader: LocalWhisperFakeAudioLoader(),
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        let active = Task {
            try await runtime.transcribe(
                modelName: "base",
                modelFolder: URL(fileURLWithPath: "/models/base"),
                audioURL: URL(fileURLWithPath: "/tmp/active-delete.wav"),
                duration: 1,
                options: DecodingOptions()
            )
        }
        #expect(await waitUntil { await pipelineProbe.activeCount == 1 })

        let deletion = Task {
            try await runtime.withReleasedPipeline {
                await deletionProbe.markStarted()
                await deletionGate.wait()
                await deletionProbe.markFinished()
            }
        }
        #expect(await waitUntil { await runtime.waitingOperationCountForTesting == 1 })

        let successor = Task {
            try await runtime.transcribe(
                modelName: "base",
                modelFolder: URL(fileURLWithPath: "/models/base"),
                audioURL: URL(fileURLWithPath: "/tmp/queued-after-delete.wav"),
                duration: 1,
                options: DecodingOptions()
            )
        }
        #expect(await waitUntil { await runtime.waitingOperationCountForTesting == 2 })

        await inferenceGate.open()
        #expect(await waitUntil { await deletionProbe.started })
        #expect(await deletionProbe.finished == false)
        #expect(await factory.loadCount == 1)
        #expect(await pipelineProbe.activeCount == 0)
        #expect(await pipelineProbe.completedCount == 1)

        await deletionGate.open()
        try await deletion.value
        _ = try await active.value
        _ = try await successor.value

        #expect(await deletionProbe.finished)
        #expect(await factory.loadCount == 2)
        #expect(await pipelineProbe.maximumActiveCount == 1)
        #expect(await pipelineProbe.completedCount == 2)
    }

    @Test func cancelledQueuedModelDeletionNeverRunsFilesystemMutation() async throws {
        let inferenceGate = LocalWhisperTestGate()
        let pipelineProbe = LocalWhisperPipelineProbe()
        let deletionProbe = LocalWhisperDeletionProbe()
        let runtime = LocalWhisperPipelineRuntime(
            factory: LocalWhisperFakePipelineFactory(
                gate: inferenceGate,
                probe: pipelineProbe
            ),
            audioLoader: LocalWhisperFakeAudioLoader(),
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        let active = Task {
            try await runtime.transcribe(
                modelName: "base",
                modelFolder: URL(fileURLWithPath: "/models/base"),
                audioURL: URL(fileURLWithPath: "/tmp/cancel-delete-active.wav"),
                duration: 1,
                options: DecodingOptions()
            )
        }
        #expect(await waitUntil { await pipelineProbe.activeCount == 1 })

        let deletion = Task {
            try await runtime.withReleasedPipeline {
                await deletionProbe.markStarted()
            }
        }
        #expect(await waitUntil { await runtime.waitingOperationCountForTesting == 1 })
        deletion.cancel()
        await #expect(throws: CancellationError.self) {
            try await deletion.value
        }

        await inferenceGate.open()
        _ = try await active.value
        #expect(await deletionProbe.started == false)
        #expect(await deletionProbe.finished == false)
    }

    @Test func overlapProducesOneCopyAndGloballyMonotonicTimeline() async throws {
        let pipeline = LocalWhisperScriptedPipeline()
        let factory = LocalWhisperFixedPipelineFactory(pipeline: pipeline)
        let loader = LocalWhisperFakeAudioLoader()
        let runtime = LocalWhisperPipelineRuntime(
            factory: factory,
            audioLoader: loader,
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        let result = try await runtime.transcribe(
            modelName: "base",
            modelFolder: URL(fileURLWithPath: "/models/base"),
            audioURL: URL(fileURLWithPath: "/tmp/overlap.wav"),
            duration: 601,
            options: DecodingOptions(language: "fr")
        )

        #expect(await loader.requests == [
            LocalWhisperAudioLoadRequest(startTime: 0, endTime: 601),
            LocalWhisperAudioLoadRequest(startTime: 595, endTime: 601),
        ])
        #expect(result.segments.map(\.text) == ["early", "boundary"])
        #expect(abs((result.segments.last?.start ?? 0) - 598.8) < 0.01)
        #expect(zip(result.segments, result.segments.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(result.language == "fr")
    }

    @Test func transcriptAssemblyPreservesLanguageDurationAndDedupedWhisperResults() throws {
        let runtimeResult = LocalWhisperRuntimeResult(
            segments: [
                TranscriptionSegment(start: 0, end: 1, text: " <|startoftranscript|> Hello "),
                TranscriptionSegment(start: 600, end: 601, text: "world"),
            ],
            language: "fr",
            timings: TranscriptionTimings()
        )

        let result = LocalWhisperTranscriber.makeTranscriptResult(
            from: runtimeResult,
            requestedLanguage: nil,
            audioDuration: 612
        )

        #expect(result.text == "Hello world")
        #expect(result.segments.map(\.startTime) == [0, 600])
        #expect(result.language == "fr")
        #expect(result.duration == 612)

        let rawResults = try #require(result.whisperResults as? [TranscriptionResult])
        #expect(rawResults.count == 1)
        #expect(rawResults[0].text == "Hello world")
        #expect(rawResults[0].segments.map(\.text) == ["Hello", "world"])
        #expect(rawResults[0].segments.map(\.start) == [0, 600])
    }

    @Test func concurrentProgressCallbacksRemainStrictlyMonotonic() async throws {
        let capture = LocalWhisperProgressCapture()
        let runtime = LocalWhisperPipelineRuntime(
            factory: LocalWhisperFixedPipelineFactory(
                pipeline: LocalWhisperConcurrentProgressPipeline()
            ),
            audioLoader: LocalWhisperFakeAudioLoader(),
            coreChunkDuration: 600,
            overlapDuration: 5
        )

        _ = try await runtime.transcribe(
            modelName: "base",
            modelFolder: URL(fileURLWithPath: "/models/base"),
            audioURL: URL(fileURLWithPath: "/tmp/progress.wav"),
            duration: 300,
            options: DecodingOptions()
        ) { completed, total in
            capture.append(completed: completed, total: total)
        }

        let updates = capture.updates
        #expect(!updates.isEmpty)
        #expect(updates.last == LocalWhisperProgressUpdate(completed: 10, total: 10))
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.completed < $1.completed })
    }

    @Test func fullyOverlappingDistinctSegmentsUseBoundedDeduplicationWork() {
        let candidates = (0..<10_000).map { index in
            LocalWhisperSegmentCandidate(
                segment: TranscriptionSegment(
                    start: 0,
                    end: 10_000,
                    text: "segment \(index)"
                ),
                chunkIndex: 0
            )
        }

        let result = LocalWhisperSegmentDeduplicator.deduplicate(candidates)

        #expect(result.segments.count == candidates.count)
        #expect(result.workUnitCount < candidates.count * 100)
    }

    @Test func fullyOverlappingAdjacentChunksUseBoundedDeduplicationWork() {
        let candidates = (0..<10_000).map { index in
            LocalWhisperSegmentCandidate(
                segment: TranscriptionSegment(
                    start: 0,
                    end: 10_000,
                    text: "segment \(index)"
                ),
                chunkIndex: index % 2
            )
        }

        let result = LocalWhisperSegmentDeduplicator.deduplicate(candidates)

        #expect(result.segments.count == candidates.count)
        #expect(result.workUnitCount < candidates.count * 100)
    }

    @Test func largeSharedTextBucketUsesLogarithmicIntervalQueries() {
        let candidates = (0..<10_000).map { index in
            LocalWhisperSegmentCandidate(
                segment: TranscriptionSegment(
                    id: index,
                    start: 0,
                    end: Float(index % 5_000 + 1),
                    text: "shared boundary phrase"
                ),
                chunkIndex: index / 5_000
            )
        }

        let result = LocalWhisperSegmentDeduplicator.deduplicate(candidates)

        #expect(result.segments.count == 5_000)
        #expect(result.workUnitCount < candidates.count * 100)
    }

    @Test func intervalIndexMatchesBruteForceOverlapSemantics() {
        var seed: UInt64 = 0xCADA_EE11
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return seed
        }

        let texts = ["Alpha", " alpha ", "Beta", "Gamma", "Delta"]
        let candidates = (0..<500).map { index in
            let start = Float(next() % 2_000) / 10
            let duration = Float((next() % 500) + 1) / 100
            return LocalWhisperSegmentCandidate(
                segment: TranscriptionSegment(
                    id: index,
                    start: start,
                    end: start + duration,
                    text: texts[Int(next() % UInt64(texts.count))]
                ),
                chunkIndex: Int(next() % 6)
            )
        }

        let indexed = LocalWhisperSegmentDeduplicator.deduplicate(candidates)
        let reference = bruteForceDeduplicate(candidates)

        #expect(indexed.segments == reference)
    }

    @Test func twentyMillisecondGridPreservesLegacyFloatBoundarySemantics() {
        let step: Float = 0.02
        let scenarios: [(previous: (Float, Float), current: (Float, Float), expected: Int)] = [
            // Exactly 25% in Float: deduplicate.
            ((0, 4 * step), (3 * step, 7 * step), 1),
            // Mathematically 25%, but legacy Float division is 0.24999996: keep.
            ((0, 8 * step), (7 * step, 11 * step), 2),
            // Legacy Float division is 0.25000006: deduplicate.
            ((0, 6 * step), (5 * step, 9 * step), 1),
            // Same below-boundary case through the `previousDuration <= currentDuration` index.
            ((step, 5 * step), (4 * step, 8 * step), 2),
        ]

        for (index, scenario) in scenarios.enumerated() {
            let candidates = [
                LocalWhisperSegmentCandidate(
                    segment: TranscriptionSegment(
                        id: index * 2,
                        start: scenario.previous.0,
                        end: scenario.previous.1,
                        text: "boundary phrase"
                    ),
                    chunkIndex: 0
                ),
                LocalWhisperSegmentCandidate(
                    segment: TranscriptionSegment(
                        id: index * 2 + 1,
                        start: scenario.current.0,
                        end: scenario.current.1,
                        text: "boundary phrase"
                    ),
                    chunkIndex: 1
                ),
            ]

            let indexed = LocalWhisperSegmentDeduplicator.deduplicate(candidates)
            let reference = bruteForceDeduplicate(candidates)

            #expect(indexed.segments == reference, "20ms-grid scenario \(index)")
            #expect(indexed.segments.count == scenario.expected, "20ms-grid scenario \(index)")
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func bruteForceDeduplicate(
        _ candidates: [LocalWhisperSegmentCandidate]
    ) -> [TranscriptionSegment] {
        let sorted = candidates.sorted {
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

        var accepted: [LocalWhisperSegmentCandidate] = []
        for candidate in sorted {
            let isDuplicate = accepted.contains { previous in
                guard abs(previous.chunkIndex - candidate.chunkIndex) == 1,
                      !previous.normalizedText.isEmpty,
                      previous.normalizedText == candidate.normalizedText else {
                    return false
                }

                let overlap = min(previous.segment.end, candidate.segment.end)
                    - max(previous.segment.start, candidate.segment.start)
                guard overlap > 0 else { return false }
                let shorterDuration = max(
                    0.001,
                    min(
                        previous.segment.end - previous.segment.start,
                        candidate.segment.end - candidate.segment.start
                    )
                )
                return overlap / shorterDuration >= 0.25
            }
            if !isDuplicate {
                accepted.append(candidate)
            }
        }

        return accepted.enumerated().map { index, candidate in
            var segment = candidate.segment
            segment.id = index
            return segment
        }
    }
}

private actor LocalWhisperTestGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor LocalWhisperPipelineProbe {
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var completedCount = 0
    private(set) var residentPipelineCount = 0
    private(set) var maximumResidentPipelineCount = 0

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
        completedCount += 1
    }

    func pipelineLoaded() {
        residentPipelineCount += 1
        maximumResidentPipelineCount = max(
            maximumResidentPipelineCount,
            residentPipelineCount
        )
    }

    func pipelineReleased() {
        residentPipelineCount -= 1
    }
}

private actor LocalWhisperReleaseProbe {
    private(set) var returned = false

    func markReturned() {
        returned = true
    }
}

private actor LocalWhisperDeletionProbe {
    private(set) var started = false
    private(set) var finished = false

    func markStarted() {
        started = true
    }

    func markFinished() {
        finished = true
    }
}

private actor LocalWhisperFakePipelineFactory: LocalWhisperPipelineFactory {
    private let gate: LocalWhisperTestGate?
    private let probe: LocalWhisperPipelineProbe
    private(set) var loadCount = 0
    private var activeLoadCount = 0
    private(set) var maximumActiveLoadCount = 0

    init(gate: LocalWhisperTestGate? = nil, probe: LocalWhisperPipelineProbe) {
        self.gate = gate
        self.probe = probe
    }

    func makePipeline(modelName: String, modelFolder: URL) async throws -> any LocalWhisperPipeline {
        activeLoadCount += 1
        maximumActiveLoadCount = max(maximumActiveLoadCount, activeLoadCount)
        await Task.yield()
        loadCount += 1
        activeLoadCount -= 1
        await probe.pipelineLoaded()
        return LocalWhisperFakePipeline(gate: gate, probe: probe)
    }
}

private struct LocalWhisperFixedPipelineFactory: LocalWhisperPipelineFactory {
    let pipeline: any LocalWhisperPipeline

    func makePipeline(modelName: String, modelFolder: URL) async throws -> any LocalWhisperPipeline {
        pipeline
    }
}

private actor LocalWhisperFakePipeline: LocalWhisperPipeline {
    private let gate: LocalWhisperTestGate?
    private let probe: LocalWhisperPipelineProbe
    private var isShutdown = false

    init(gate: LocalWhisperTestGate?, probe: LocalWhisperPipelineProbe) {
        self.gate = gate
        self.probe = probe
    }

    func transcribe(
        audioArray: [Float],
        options: DecodingOptions,
        progress: (@Sendable (TranscriptionProgress) -> Bool?)?
    ) async throws -> [LocalWhisperPipelineResult] {
        await probe.enter()
        if let gate {
            await gate.wait()
        } else {
            try await Task.sleep(for: .milliseconds(20))
        }
        await probe.leave()
        return []
    }

    func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        await probe.pipelineReleased()
    }
}

private actor LocalWhisperScriptedPipeline: LocalWhisperPipeline {
    func transcribe(
        audioArray: [Float],
        options: DecodingOptions,
        progress: (@Sendable (TranscriptionProgress) -> Bool?)?
    ) async throws -> [LocalWhisperPipelineResult] {
        let loadStart = TimeInterval(audioArray.first ?? 0)
        let segments: [TranscriptionSegment]
        if loadStart == 0 {
            segments = [
                TranscriptionSegment(start: 10, end: 11, text: "early"),
                TranscriptionSegment(start: 598.8, end: 600.8, text: "boundary"),
            ]
        } else {
            segments = [
                TranscriptionSegment(start: 4.2, end: 6.2, text: "boundary"),
            ]
        }
        return [
            LocalWhisperPipelineResult(
                segments: segments,
                language: options.language ?? "en",
                timings: TranscriptionTimings()
            )
        ]
    }

    func shutdown() async {}
}

private actor LocalWhisperConcurrentProgressPipeline: LocalWhisperPipeline {
    func transcribe(
        audioArray: [Float],
        options: DecodingOptions,
        progress: (@Sendable (TranscriptionProgress) -> Bool?)?
    ) async throws -> [LocalWhisperPipelineResult] {
        await withTaskGroup(of: Void.self) { group in
            for windowID in [7, 1, 5, 3, 9, 2, 8, 4, 6, 0] {
                group.addTask {
                    _ = progress?(
                        TranscriptionProgress(
                            timings: TranscriptionTimings(),
                            text: "",
                            tokens: [],
                            windowId: windowID
                        )
                    )
                }
            }
        }
        return []
    }

    func shutdown() async {}
}

private actor LocalWhisperFakeAudioLoader: LocalWhisperAudioChunkLoading {
    private(set) var requests: [LocalWhisperAudioLoadRequest] = []

    func loadAudio(
        at url: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws -> [Float] {
        requests.append(LocalWhisperAudioLoadRequest(startTime: startTime, endTime: endTime))
        return [Float(startTime)]
    }
}

private struct LocalWhisperProgressUpdate: Equatable {
    let completed: Int
    let total: Int
}

private final class LocalWhisperProgressCapture: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [LocalWhisperProgressUpdate]())

    var updates: [LocalWhisperProgressUpdate] {
        lock.withLock { $0 }
    }

    func append(completed: Int, total: Int) {
        lock.withLock {
            $0.append(LocalWhisperProgressUpdate(completed: completed, total: total))
        }
    }
}
