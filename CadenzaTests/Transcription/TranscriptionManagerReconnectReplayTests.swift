import Foundation
import Testing
@testable import Cadenza

private enum ReplayTestFailure: Error, Sendable {
    case stream
    case send
}

/// A realtime service whose stream and sends the test drives by hand.
private actor ReplayTestService: TranscriptionService {
    nonisolated let reportsFinalizedAudio: Bool
    private var streamContinuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    private var blockedSend: CheckedContinuation<Bool, Never>?
    private var blocksNextSend = false
    private(set) var startCount = 0
    private(set) var received = Data()

    init(reportsFinalizedAudio: Bool) {
        self.reportsFinalizedAudio = reportsFinalizedAudio
    }

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        startCount += 1
        let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
        streamContinuation = pair.continuation
        return pair.stream
    }

    func sendAudio(_ data: Data) async throws {
        if blocksNextSend {
            blocksNextSend = false
            let fails = await withCheckedContinuation { blockedSend = $0 }
            if fails { throw ReplayTestFailure.send }
        }
        received.append(data)
    }

    func stopRealtimeSession() async throws {
        streamContinuation?.finish()
    }

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        throw TranscriptionError.notSupported("test-only realtime service")
    }

    func emit(_ text: String, isFinal: Bool, finalizedAudioBytes: Int? = nil) {
        streamContinuation?.yield(TranscriptDelta(
            text: text,
            isFinal: isFinal,
            language: "en",
            finalizedAudioBytes: finalizedAudioBytes
        ))
    }

    func failStream() {
        streamContinuation?.finish(throwing: ReplayTestFailure.stream)
    }

    func blockNextSend() {
        blocksNextSend = true
    }

    var isSendBlocked: Bool { blockedSend != nil }

    func releaseSend(failing: Bool) {
        let continuation = blockedSend
        blockedSend = nil
        continuation?.resume(returning: failing)
    }
}

@MainActor
private final class ReplayServiceFactory {
    private let services: [ReplayTestService]
    private var index = 0

    init(_ services: [ReplayTestService]) {
        self.services = services
    }

    func makeFactory() -> RealtimeTranscriptionServiceFactory {
        { [weak self] _, _, _, _ in
            guard let self, self.index < self.services.count else {
                throw TranscriptionError.notSupported("No replay test service configured")
            }
            defer { self.index += 1 }
            return self.services[self.index]
        }
    }
}

@Suite("Realtime reconnect audio replay", .serialized)
@MainActor
struct TranscriptionManagerReconnectReplayTests {
    /// Distinct fictional PCM so the order of replayed audio is checkable.
    private func chunk(_ marker: UInt8, bytes: Int = 1_000) -> Data {
        Data(repeating: marker, count: bytes)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Starts `first`, wiring the failure handler the way RecordingEngine does
    /// when it decides to reconnect.
    private func startFirstSession(_ manager: TranscriptionManager) async throws {
        manager.onRealtimeFailure = { [weak manager] _, _, _ in
            manager?.holdRealtimeAudioForReconnect()
        }
        try await manager.startRealtime(provider: .openai, apiKey: "fictional")
    }

    /// The manager batches deltas and flushes a lone hypothesis only once
    /// 180 ms have passed since its last flush.
    private func emitHypothesis(_ text: String, from service: ReplayTestService) async {
        try? await Task.sleep(for: .milliseconds(250))
        await service.emit(text, isFinal: false)
    }

    private func replace(_ manager: TranscriptionManager) async throws {
        let stop = manager.beginRealtimeStop(preserveFailureHandler: true, retainAudioForReplay: true)
        await manager.finishRealtimeStop(stop)
        try await manager.startRealtime(provider: .openai, apiKey: "fictional", preserveSegments: true)
    }

    @Test func replacementReceivesUnfinalizedThenHeldAudioAndDropsTheStaleHypothesis() async throws {
        let first = ReplayTestService(reportsFinalizedAudio: true)
        let second = ReplayTestService(reportsFinalizedAudio: true)
        let factory = ReplayServiceFactory([first, second])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        defer { manager.reset() }
        try await startFirstSession(manager)

        manager.sendAudio(chunk(1))
        manager.sendAudio(chunk(2))
        #expect(await waitUntil { await first.received.count == 2_000 })
        await first.emit("Hello.", isFinal: true, finalizedAudioBytes: 1_000)
        await emitHypothesis("wor", from: first)
        #expect(await waitUntil { manager.segments.map(\.text) == ["Hello.", "wor"] })

        await first.failStream()
        #expect(await waitUntil { manager.acceptsRealtimeAudio && !manager.isTranscribing })
        manager.sendAudio(chunk(3))

        try await replace(manager)
        #expect(await waitUntil { await second.received == chunk(2) + chunk(3) })
        // The replay regenerates "wor", so the stale hypothesis must not stay.
        #expect(manager.segments.map(\.text) == ["Hello."])
        #expect(await first.received == chunk(1) + chunk(2))

        manager.sendAudio(chunk(4))
        #expect(await waitUntil { await second.received == chunk(2) + chunk(3) + chunk(4) })
    }

    @Test func providerWithoutFinalizedReportsReplaysOnlyAudioItNeverReceived() async throws {
        let first = ReplayTestService(reportsFinalizedAudio: false)
        let second = ReplayTestService(reportsFinalizedAudio: false)
        let factory = ReplayServiceFactory([first, second])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        defer { manager.reset() }
        try await startFirstSession(manager)

        manager.sendAudio(chunk(1))
        #expect(await waitUntil { await first.received.count == 1_000 })
        await emitHypothesis("wor", from: first)
        #expect(await waitUntil { manager.segments.map(\.text) == ["wor"] })

        await first.failStream()
        #expect(await waitUntil { manager.acceptsRealtimeAudio && !manager.isTranscribing })
        manager.sendAudio(chunk(2))

        try await replace(manager)
        #expect(await waitUntil { await second.received == chunk(2) })
        // Without a finalized offset, resending chunk 1 could duplicate text.
        #expect(manager.segments.map(\.text) == ["wor"])
    }

    @Test func audioQueuedBehindAFailedSendIsReplayedInOrder() async throws {
        let first = ReplayTestService(reportsFinalizedAudio: true)
        let second = ReplayTestService(reportsFinalizedAudio: true)
        let factory = ReplayServiceFactory([first, second])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        defer { manager.reset() }
        try await startFirstSession(manager)

        await first.blockNextSend()
        manager.sendAudio(chunk(1))
        #expect(await waitUntil { await first.isSendBlocked })
        manager.sendAudio(chunk(2))
        manager.sendAudio(chunk(3))
        await first.releaseSend(failing: true)
        #expect(await waitUntil { manager.realtimeError != nil })
        manager.sendAudio(chunk(4))

        try await replace(manager)
        // 1 failed in flight, 2 and 3 were still queued, 4 arrived while held.
        #expect(await waitUntil {
            await second.received == chunk(1) + chunk(2) + chunk(3) + chunk(4)
        })
    }

    @Test func anyOtherStopDiscardsHeldAudio() async throws {
        let first = ReplayTestService(reportsFinalizedAudio: true)
        let second = ReplayTestService(reportsFinalizedAudio: true)
        let factory = ReplayServiceFactory([first, second])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        defer { manager.reset() }
        try await startFirstSession(manager)

        manager.sendAudio(chunk(1))
        #expect(await waitUntil { await first.received.count == 1_000 })
        await first.failStream()
        #expect(await waitUntil { manager.acceptsRealtimeAudio && !manager.isTranscribing })
        manager.sendAudio(chunk(2))

        let stop = manager.beginRealtimeStop(preserveFailureHandler: true)
        #expect(!manager.acceptsRealtimeAudio)
        await manager.finishRealtimeStop(stop)
        try await manager.startRealtime(provider: .openai, apiKey: "fictional", preserveSegments: true)
        manager.sendAudio(chunk(3))
        #expect(await waitUntil { await second.received == chunk(3) })
    }

    @Test func releasingTheHoldStopsBuffering() async throws {
        let manager = TranscriptionManager()
        let id = manager.holdRealtimeAudioForReconnect()
        #expect(manager.acceptsRealtimeAudio)
        #expect(manager.holdRealtimeAudioForReconnect() == id)

        manager.releaseHeldRealtimeAudio(UUID())
        #expect(manager.acceptsRealtimeAudio)
        manager.releaseHeldRealtimeAudio(id)
        #expect(!manager.acceptsRealtimeAudio)
    }
}

@Suite("Realtime audio backlog")
struct RealtimeAudioBacklogTests {
    private func bytes(_ data: [Data]) -> Data {
        data.reduce(Data(), +)
    }

    @Test func coalescesSmallChunksIntoBlocks() {
        var backlog = RealtimeAudioBacklog(capacity: 1_000_000)
        for index in 0..<100 {
            backlog.append(Data(repeating: UInt8(index), count: 1_024))
        }
        #expect(backlog.byteCount == 102_400)
        #expect(backlog.blocks.count == 3)
        #expect(bytes(backlog.blocks).count == 102_400)
    }

    @Test func capacityDropsTheOldestBytes() {
        var backlog = RealtimeAudioBacklog(capacity: 4_000)
        backlog.append(Data(repeating: 1, count: 3_000))
        backlog.append(Data(repeating: 2, count: 3_000))
        #expect(backlog.byteCount == 4_000)
        #expect(backlog.startOffset == 2_000)
        #expect(bytes(backlog.blocks) == Data(repeating: 1, count: 1_000) + Data(repeating: 2, count: 3_000))
    }

    @Test func discardKeepsOnlyAudioAfterTheOffset() {
        var backlog = RealtimeAudioBacklog(capacity: 1_000_000)
        backlog.append(Data(repeating: 1, count: 1_000))
        backlog.append(Data(repeating: 2, count: 1_000))
        backlog.discard(before: 1_500)
        #expect(backlog.startOffset == 1_500)
        #expect(bytes(backlog.blocks) == Data(repeating: 2, count: 500))
        // An offset already discarded changes nothing.
        backlog.discard(before: 1_000)
        #expect(backlog.byteCount == 500)
        backlog.discard(before: 9_000)
        #expect(backlog.isEmpty)
    }

    @Test func trimmingStaysSampleAligned() {
        var backlog = RealtimeAudioBacklog(capacity: 1_000_000)
        backlog.append(Data(repeating: 1, count: 1_000))
        backlog.discard(before: 301)
        #expect(backlog.startOffset == 300)
        #expect(backlog.byteCount == 700)
    }
}
