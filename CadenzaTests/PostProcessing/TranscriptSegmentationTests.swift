import Testing
import Foundation
@testable import Cadenza

@Suite("Transcript Segmentation")
@MainActor
struct TranscriptSegmentationTests {

    @Test func shortSegmentsPassThrough() {
        let entries = [
            TranscriptEntry(startTime: 0, endTime: 30, text: "Short segment."),
            TranscriptEntry(startTime: 30, endTime: 55, text: "Another short one.")
        ]
        let result = PostProcessingCoordinator.subdivideCoarseSegments(entries, maxDuration: 60)
        #expect(result.count == 2)
        #expect(result[0].text == "Short segment.")
        #expect(result[1].text == "Another short one.")
    }

    @Test func longSegmentIsSplit() {
        let text = "First sentence. Second sentence. Third sentence. Fourth sentence."
        let entries = [
            TranscriptEntry(startTime: 0, endTime: 120, text: text)
        ]
        let result = PostProcessingCoordinator.subdivideCoarseSegments(entries, maxDuration: 60)
        #expect(result.count > 1)
        #expect(result.first!.startTime == 0)
        #expect(abs(result.last!.endTime - 120) < 0.01)
        let joined = result.map(\.text).joined(separator: " ")
        #expect(joined == text)
    }

    @Test func preservesSpeaker() {
        let entries = [
            TranscriptEntry(startTime: 0, endTime: 90, text: "Hello there. How are you? I'm fine.", speaker: "Alice")
        ]
        let result = PostProcessingCoordinator.subdivideCoarseSegments(entries, maxDuration: 60)
        for entry in result {
            #expect(entry.speaker == "Alice")
        }
    }

    @Test func handlesNoSentenceBoundary() {
        let text = String(repeating: "word ", count: 200)
        let entries = [
            TranscriptEntry(startTime: 0, endTime: 120, text: text)
        ]
        let result = PostProcessingCoordinator.subdivideCoarseSegments(entries, maxDuration: 60)
        #expect(result.count == 1)
        #expect(result[0].text == text)
    }

    @Test func cjkSentenceBoundaries() {
        let text = "这是第一句话。这是第二句话。这是第三句话。这是第四句话。"
        let entries = [
            TranscriptEntry(startTime: 0, endTime: 120, text: text)
        ]
        let result = PostProcessingCoordinator.subdivideCoarseSegments(entries, maxDuration: 60)
        #expect(result.count > 1)
        let joined = result.map(\.text).joined(separator: "")
        #expect(joined.contains("第一句话"))
        #expect(joined.contains("第四句话"))
    }

    @Test func mixedShortAndLongSegments() {
        let entries = [
            TranscriptEntry(startTime: 0, endTime: 20, text: "Short."),
            TranscriptEntry(startTime: 20, endTime: 140, text: "Long first sentence. Long second sentence. Long third sentence.", speaker: "Bob"),
            TranscriptEntry(startTime: 140, endTime: 160, text: "Short again.")
        ]
        let result = PostProcessingCoordinator.subdivideCoarseSegments(entries, maxDuration: 60)
        #expect(result.count >= 4)
        #expect(result.first!.text == "Short.")
        #expect(result.last!.text == "Short again.")
    }

    @Test func timestampsAreMonotonic() {
        let text = "One sentence here. Another sentence here. A third one. And a fourth."
        let entries = [
            TranscriptEntry(startTime: 10, endTime: 130, text: text)
        ]
        let result = PostProcessingCoordinator.subdivideCoarseSegments(entries, maxDuration: 60)
        for i in 1..<result.count {
            #expect(result[i].startTime >= result[i - 1].startTime)
            #expect(result[i].startTime == result[i - 1].endTime)
        }
    }
}

@Suite("Provider Segment Merge")
struct ProviderSegmentMergeTests {
    private func seg(
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String,
        _ speaker: String? = nil
    ) -> TranscriptResultSegment {
        TranscriptResultSegment(startTime: start, endTime: end, text: text, speaker: speaker)
    }

    @Test func unlabeledSegmentsNeverMerge() {
        let merged = WhisperTranscriber.mergeSameSpeakerSegments([
            seg(0, 10, "One."), seg(10, 20, "Two."), seg(20, 30, "Three.")
        ])
        #expect(merged.count == 3)
    }

    @Test func sameSpeakerRunsMerge() {
        let merged = WhisperTranscriber.mergeSameSpeakerSegments([
            seg(0, 10, "Hello", "A"), seg(10, 20, "again", "A"), seg(20, 30, "Bob here", "B")
        ])
        #expect(merged.count == 2)
        #expect(merged[0].text == "Hello again")
        #expect(merged[0].speaker == "A")
        #expect(merged[0].startTime == 0)
        #expect(merged[0].endTime == 20)
    }

    @Test func mergeCapsAtThirtySeconds() {
        let merged = WhisperTranscriber.mergeSameSpeakerSegments([
            seg(0, 15, "a", "A"), seg(15, 30, "b", "A"),
            seg(30, 45, "c", "A"), seg(45, 60, "d", "A")
        ])
        #expect(merged.count == 2)
        #expect(merged[0].endTime == 30)
        #expect(merged[1].startTime == 30)
    }

    @Test func mergeCapsAtFiveHundredCharacters() {
        let longText = String(repeating: "x", count: 501)
        let merged = WhisperTranscriber.mergeSameSpeakerSegments([
            seg(0, 5, longText, "A"), seg(5, 10, "tail", "A")
        ])
        #expect(merged.count == 2)
    }

    @Test func speakerChangeAlwaysBreaks() {
        let merged = WhisperTranscriber.mergeSameSpeakerSegments([
            seg(0, 5, "hi", "A"), seg(5, 10, "hey", "B"), seg(10, 15, "yo", "A")
        ])
        #expect(merged.count == 3)
    }

    @Test func uniformSpeakerResponseStaysChunked() {
        // Regression guard: a diarized response whose speaker fields are
        // uniform across a five-minute chunk used to collapse into a single
        // monolith that no later diarization pass could re-label.
        let segments = (0..<20).map { i in
            seg(TimeInterval(i * 15), TimeInterval((i + 1) * 15), "sentence \(i).", "A")
        }
        let merged = WhisperTranscriber.mergeSameSpeakerSegments(segments)
        #expect(merged.count >= 10)
        #expect(merged.allSatisfy { $0.endTime - $0.startTime <= 30.001 })
    }
}

@Suite("Speaker Assignment")
@MainActor
struct SpeakerAssignmentTests {
    @Test func recordingWideSpansCorrectLabelsThatSwapAcrossChunks() {
        var entries = [
            TranscriptEntry(startTime: 0, endTime: 4, text: "First", speaker: "A"),
            TranscriptEntry(startTime: 4, endTime: 8, text: "Second", speaker: "B"),
            TranscriptEntry(startTime: 300, endTime: 304, text: "Third", speaker: "A"),
            TranscriptEntry(startTime: 304, endTime: 308, text: "Fourth", speaker: "B")
        ]
        let spans = [
            SpeakerAssignmentSpan(speakerID: 42, startTime: 0, endTime: 4),
            SpeakerAssignmentSpan(speakerID: 7, startTime: 4, endTime: 8),
            SpeakerAssignmentSpan(speakerID: 7, startTime: 300, endTime: 304),
            SpeakerAssignmentSpan(speakerID: 42, startTime: 304, endTime: 308)
        ]

        SpeakerDiarizer.shared.assignSpeakers(
            entries: &entries,
            spans: spans,
            replaceExistingSpeakers: true
        )

        #expect(entries.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 2", "Speaker 1"])
        #expect(Set(entries.compactMap(\.speaker)).count == 2)
    }

    @Test func recordingWideSpansCollapseExtraProviderLabelsForSameVoice() {
        var entries = [
            TranscriptEntry(startTime: 0, endTime: 2, text: "One", speaker: "A"),
            TranscriptEntry(startTime: 10, endTime: 12, text: "Two", speaker: "D"),
            TranscriptEntry(startTime: 20, endTime: 22, text: "Three", speaker: "E")
        ]
        let spans = [
            SpeakerAssignmentSpan(speakerID: 3, startTime: 0, endTime: 2),
            SpeakerAssignmentSpan(speakerID: 3, startTime: 10, endTime: 12),
            SpeakerAssignmentSpan(speakerID: 3, startTime: 20, endTime: 22)
        ]

        SpeakerDiarizer.shared.assignSpeakers(
            entries: &entries,
            spans: spans,
            replaceExistingSpeakers: true
        )

        #expect(entries.map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 1"])
    }

    @Test func ambiguousOverlapBecomesUnknownInsteadOfGuessing() {
        var entries = [
            TranscriptEntry(startTime: 0, endTime: 10, text: "Interrupted", speaker: "A")
        ]
        let spans = [
            SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 5),
            SpeakerAssignmentSpan(speakerID: 1, startTime: 5, endTime: 10)
        ]

        SpeakerDiarizer.shared.assignSpeakers(
            entries: &entries,
            spans: spans,
            replaceExistingSpeakers: true
        )

        #expect(entries[0].speaker == nil)
    }

    @Test func tinyOverlapDoesNotLabelMostlyUnsupportedEntry() {
        var entries = [
            TranscriptEntry(startTime: 0, endTime: 100, text: "Mostly unsupported", speaker: "A")
        ]
        let spans = [
            SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 1)
        ]

        SpeakerDiarizer.shared.assignSpeakers(
            entries: &entries,
            spans: spans,
            replaceExistingSpeakers: true
        )

        #expect(entries[0].speaker == nil)
    }

    @Test func fillOnlyModePreservesExistingProviderLabel() {
        var entries = [
            TranscriptEntry(startTime: 0, endTime: 4, text: "Existing", speaker: "A"),
            TranscriptEntry(startTime: 4, endTime: 8, text: "Missing")
        ]
        let spans = [
            SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 4),
            SpeakerAssignmentSpan(speakerID: 1, startTime: 4, endTime: 8)
        ]

        SpeakerDiarizer.shared.assignSpeakers(
            entries: &entries,
            spans: spans,
            replaceExistingSpeakers: false
        )

        #expect(entries[0].speaker == "A")
        #expect(entries[1].speaker == "Speaker 2")
    }
}

@Suite("Speaker Diarization Gate")
@MainActor
struct SpeakerDiarizationGateTests {
    @Test func runsOperationsOneAtATimeInFIFOOrder() async throws {
        let gate = SpeakerDiarizationGate()
        let firstStarted = SpeakerGateTestLatch()
        let releaseFirst = SpeakerGateTestLatch()
        var events: [String] = []

        let first = Task { @MainActor in
            try await gate.withPermit {
                events.append("first-start")
                firstStarted.open()
                await releaseFirst.wait()
                events.append("first-end")
            }
        }
        await firstStarted.wait()

        let second = Task { @MainActor in
            try await gate.withPermit {
                events.append("second-start")
                await Task.yield()
                events.append("second-end")
            }
        }
        await waitUntil { gate.queuedRequestCount == 1 }

        let third = Task { @MainActor in
            try await gate.withPermit {
                events.append("third-start")
                await Task.yield()
                events.append("third-end")
            }
        }
        await waitUntil { gate.queuedRequestCount == 2 }

        #expect(events == ["first-start"])
        releaseFirst.open()
        try await first.value
        try await second.value
        try await third.value

        #expect(events == [
            "first-start", "first-end",
            "second-start", "second-end",
            "third-start", "third-end"
        ])
        #expect(!gate.hasActivePermit)
        #expect(gate.queuedRequestCount == 0)
    }

    @Test func cancellingQueuedRequestPreservesPermitForNextWaiter() async throws {
        let gate = SpeakerDiarizationGate()
        let firstStarted = SpeakerGateTestLatch()
        let releaseFirst = SpeakerGateTestLatch()
        var events: [String] = []

        let first = Task { @MainActor in
            try await gate.withPermit {
                events.append("first")
                firstStarted.open()
                await releaseFirst.wait()
            }
        }
        await firstStarted.wait()

        let cancelled = Task { @MainActor in
            try await gate.withPermit {
                events.append("cancelled-request-ran")
            }
        }
        await waitUntil { gate.queuedRequestCount == 1 }

        let follower = Task { @MainActor in
            try await gate.withPermit {
                events.append("follower")
            }
        }
        await waitUntil { gate.queuedRequestCount == 2 }

        cancelled.cancel()
        let cancellationResult = await cancelled.result
        if case .failure(let error) = cancellationResult {
            #expect(error is CancellationError)
        } else {
            Issue.record("Cancelled queued request unexpectedly succeeded")
        }
        await waitUntil { gate.queuedRequestCount == 1 }

        releaseFirst.open()
        try await first.value
        try await follower.value

        #expect(events == ["first", "follower"])
        #expect(!gate.hasActivePermit)
        #expect(gate.queuedRequestCount == 0)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        attempts: Int = 1_000
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for SpeakerDiarizationGate state")
    }
}

@MainActor
private final class SpeakerGateTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
