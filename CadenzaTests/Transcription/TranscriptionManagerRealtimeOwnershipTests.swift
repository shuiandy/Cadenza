import Foundation
import Testing
@testable import Cadenza

private enum ControlledHandshakeFailure: Error, Sendable {
    case rejected
}

private enum ControlledRealtimeFailure: Error, Sendable {
    case audioSend
    case stream
}

private actor ControlledGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor ControlledCompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

private actor ControlledRealtimeService: TranscriptionService {
    private enum HandshakeOutcome: Sendable {
        case ready
        case failure
    }

    private var handshakeContinuation: CheckedContinuation<HandshakeOutcome, Never>?
    private var streamContinuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    private let blocksAudioSend: Bool
    private let blocksStop: Bool
    private let finishesStreamOnStop: Bool
    private let finalTextOnStop: String?
    private var audioSendContinuation: CheckedContinuation<Bool, Never>?
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var didReturnReadyStream = false
    private var didEmitFinalTextOnStop = false
    private(set) var startCount = 0
    private(set) var sendStartCount = 0
    private(set) var pendingStopCount = 0
    private(set) var readyStopCount = 0
    private(set) var sentAudio: [Data] = []

    init(
        blocksAudioSend: Bool = false,
        blocksStop: Bool = false,
        finishesStreamOnStop: Bool = true,
        finalTextOnStop: String? = nil
    ) {
        self.blocksAudioSend = blocksAudioSend
        self.blocksStop = blocksStop
        self.finishesStreamOnStop = finishesStreamOnStop
        self.finalTextOnStop = finalTextOnStop
    }

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        startCount += 1
        // A provider callback bridged through a checked continuation does not
        // automatically resume when its caller is cancelled. This deliberately
        // models that non-cooperative handshake.
        let outcome = await withCheckedContinuation { continuation in
            handshakeContinuation = continuation
        }

        switch outcome {
        case .ready:
            let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
            streamContinuation = pair.continuation
            didReturnReadyStream = true
            return pair.stream
        case .failure:
            throw ControlledHandshakeFailure.rejected
        }
    }

    func sendAudio(_ data: Data) async throws {
        sendStartCount += 1
        if blocksAudioSend {
            let shouldFail = await withCheckedContinuation { continuation in
                audioSendContinuation = continuation
            }
            if shouldFail {
                throw ControlledRealtimeFailure.audioSend
            }
        }
        sentAudio.append(data)
    }

    func stopRealtimeSession() async throws {
        if didReturnReadyStream {
            readyStopCount += 1
        } else {
            pendingStopCount += 1
        }
        if !didEmitFinalTextOnStop, let finalTextOnStop {
            didEmitFinalTextOnStop = true
            streamContinuation?.yield(
                TranscriptDelta(text: finalTextOnStop, isFinal: true, language: "en")
            )
        }
        if finishesStreamOnStop {
            streamContinuation?.finish()
        }
        if blocksStop {
            await withCheckedContinuation { continuation in
                stopContinuations.append(continuation)
            }
        }
    }

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        throw TranscriptionError.notSupported("test-only realtime service")
    }

    func completeHandshake() {
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        continuation?.resume(returning: .ready)
    }

    func rejectHandshake() {
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        continuation?.resume(returning: .failure)
    }

    func emit(_ text: String, isFinal: Bool = true) {
        streamContinuation?.yield(TranscriptDelta(text: text, isFinal: isFinal, language: "en"))
    }

    func finishStream() {
        streamContinuation?.finish()
    }

    func failStream() {
        streamContinuation?.finish(throwing: ControlledRealtimeFailure.stream)
    }

    func releaseAudioSend(failing: Bool) {
        let continuation = audioSendContinuation
        audioSendContinuation = nil
        continuation?.resume(returning: failing)
    }

    func releaseStop() {
        let continuations = stopContinuations
        stopContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    var isStopWaiting: Bool {
        !stopContinuations.isEmpty
    }
}

@MainActor
private final class RealtimeServiceFactorySpy {
    private var services: [any TranscriptionService]
    private var nextIndex = 0
    private(set) var providers: [AIProvider] = []

    init(_ services: [any TranscriptionService]) {
        self.services = services
    }

    func makeFactory() -> RealtimeTranscriptionServiceFactory {
        { [weak self] provider, _, _, _ in
            guard let self, self.nextIndex < self.services.count else {
                throw TranscriptionError.notSupported("No test service configured")
            }
            self.providers.append(provider)
            defer { self.nextIndex += 1 }
            return self.services[self.nextIndex]
        }
    }
}

@Suite("Realtime transcription session ownership", .serialized)
@MainActor
struct TranscriptionManagerRealtimeOwnershipTests {
    private func waitUntil(
        timeout: Duration = .milliseconds(500),
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

    @Test func stoppedPendingHandshakeCannotReplaceOrCommitIntoNewSession() async throws {
        let serviceA = ControlledRealtimeService()
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })

        await manager.stopRealtime(abandonStartup: true)
        #expect(await waitUntil { await serviceA.pendingStopCount == 1 })

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value

        await serviceB.emit("B-LIVE")
        #expect(await waitUntil { manager.fullText == "B-LIVE" })
        manager.sendAudio(Data([0xB0]))
        #expect(await waitUntil { await serviceB.sentAudio == [Data([0xB0])] })

        await serviceA.completeHandshake()
        await #expect(throws: CancellationError.self) {
            try await startA.value
        }
        await serviceA.emit("STALE-A")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(manager.fullText == "B-LIVE")
        #expect(await serviceA.sentAudio.isEmpty)
        #expect(await serviceA.readyStopCount == 1)

        manager.sendAudio(Data([0xB1]))
        #expect(await waitUntil {
            await serviceB.sentAudio == [Data([0xB0]), Data([0xB1])]
        })
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func resetInvalidatesPendingHandshakeBeforeNewSessionStarts() async throws {
        let serviceA = ControlledRealtimeService()
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        manager.reset()

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value
        await serviceB.emit("B-AFTER-RESET")
        #expect(await waitUntil { manager.fullText == "B-AFTER-RESET" })

        await serviceA.completeHandshake()
        await #expect(throws: CancellationError.self) {
            try await startA.value
        }
        await serviceA.emit("STALE-AFTER-RESET")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.fullText == "B-AFTER-RESET")
        #expect(await serviceA.readyStopCount == 1)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func rejectedPendingHandshakeClosesItsExactService() async {
        let service = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await service.startCount == 1 })
        await service.rejectHandshake()
        await #expect(throws: ControlledHandshakeFailure.rejected) {
            try await start.value
        }

        #expect(await waitUntil { await service.pendingStopCount == 1 })
        #expect(manager.realtimeProvider == nil)
        #expect(manager.isTranscribing == false)
    }

    @Test func cancelledPendingHandshakeClosesAfterItsLateCompletion() async {
        let service = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await service.startCount == 1 })
        start.cancel()
        await service.completeHandshake()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(await waitUntil { await service.readyStopCount == 1 })
        #expect(manager.realtimeProvider == nil)
        #expect(manager.isTranscribing == false)
    }

    @Test func cancellationAtEntryDoesNotConstructAService() async {
        let service = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        start.cancel()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(await service.startCount == 0)
        #expect(factory.providers.isEmpty)
    }

    @Test func pendingSessionBusyIsReportedAsAnError() async {
        let serviceA = ControlledRealtimeService()
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })

        var didThrow = false
        do {
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(await serviceB.startCount == 0)
        manager.reset()
        await serviceA.completeHandshake()
        _ = try? await startA.value
    }

    @Test func activeSessionBusyIsReportedAsAnError() async throws {
        let serviceA = ControlledRealtimeService()
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value

        var didThrow = false
        do {
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(await serviceB.startCount == 0)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func closingSessionBusyIsReportedAsAnError() async throws {
        let serviceA = ControlledRealtimeService()
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value
        await serviceA.finishStream()
        #expect(await waitUntil { manager.isTranscribing == false })

        var didThrow = false
        do {
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(await serviceB.startCount == 0)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func delayedOldHandleFinishCannotClearReplacementSession() async throws {
        let serviceA = ControlledRealtimeService()
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        let oldCleanupGate = ControlledGate()

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value

        let oldStopHandle = manager.beginRealtimeStop()
        manager.reset()
        let delayedOldFinish = Task { @MainActor in
            await oldCleanupGate.wait()
            await manager.finishRealtimeStop(oldStopHandle, abandonStartup: true)
        }
        #expect(await waitUntil { await oldCleanupGate.isWaiting })

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value
        await serviceB.emit("B-LIVE")
        #expect(await waitUntil { manager.fullText == "B-LIVE" })

        await oldCleanupGate.release()
        await delayedOldFinish.value

        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(manager.fullText == "B-LIVE")
        manager.sendAudio(Data([0xB0]))
        #expect(await waitUntil { await serviceB.sentAudio == [Data([0xB0])] })
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func cancelledStaleStartCannotChangeActiveSessionTimestampBase() async throws {
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        let startDateB = Date().addingTimeInterval(-10)
        let staleStartGate = ControlledGate()

        let startB = Task { @MainActor in
            try await manager.startRealtime(
                provider: .gemini,
                apiKey: "fake-b",
                recordingStartTime: startDateB
            )
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value

        let staleStartA = Task { @MainActor in
            await staleStartGate.wait()
            try await manager.startRealtime(
                provider: .openai,
                apiKey: "fake-a",
                recordingStartTime: Date().addingTimeInterval(-1_000)
            )
        }
        #expect(await waitUntil { await staleStartGate.isWaiting })
        staleStartA.cancel()
        await staleStartGate.release()
        await #expect(throws: CancellationError.self) {
            try await staleStartA.value
        }

        await serviceB.emit("B-TIMED")
        #expect(await waitUntil { manager.fullText == "B-TIMED" })
        let timestamp = try #require(manager.segments.first?.timestamp)
        #expect(timestamp > 5 && timestamp < 30)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func closingOldHandleLateCallbacksCannotMutateReplacement() async throws {
        let serviceA = ControlledRealtimeService(blocksAudioSend: true, blocksStop: true)
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(
            realtimeServiceFactory: factory.makeFactory(),
            realtimeWatchdogDelay: .milliseconds(40)
        )

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value
        manager.sendAudio(Data([0xA0]))
        #expect(await waitUntil { await serviceA.sendStartCount == 1 })

        let oldHandle = manager.beginRealtimeStop()
        manager.reset()
        let finishA = Task { @MainActor in
            await manager.finishRealtimeStop(oldHandle)
        }

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value

        var failures: [AIProvider] = []
        manager.onRealtimeFailure = { _, provider, _ in failures.append(provider) }
        manager.setRealtimeHint("B-HINT")
        await serviceB.emit("B-LIVE")
        #expect(await waitUntil { manager.fullText == "B-LIVE" })
        manager.sendAudio(Data([0xB0]))
        #expect(await waitUntil { await serviceB.sentAudio == [Data([0xB0])] })

        // A is detached but its stream, audio send, watchdog, and close can all
        // resume after B owns the manager.
        await serviceA.emit("STALE-A")
        await serviceA.failStream()
        await serviceA.releaseAudioSend(failing: true)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await waitUntil(timeout: .seconds(1)) { await serviceA.isStopWaiting })
        await serviceA.releaseStop()
        await finishA.value
        try? await Task.sleep(for: .milliseconds(30))

        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(manager.fullText == "B-LIVE")
        #expect(manager.realtimeError == "B-HINT")
        #expect(failures.isEmpty)
        #expect(await serviceA.sentAudio.isEmpty)
        manager.sendAudio(Data([0xB1]))
        #expect(await waitUntil {
            await serviceB.sentAudio == [Data([0xB0]), Data([0xB1])]
        })
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func activeAbandonStartupLateCallbacksCannotMutateReplacement() async throws {
        let serviceA = ControlledRealtimeService(blocksAudioSend: true, blocksStop: true)
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(
            realtimeServiceFactory: factory.makeFactory(),
            realtimeWatchdogDelay: .milliseconds(40)
        )

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value
        manager.sendAudio(Data([0xA0]))
        #expect(await waitUntil { await serviceA.sendStartCount == 1 })

        await manager.stopRealtime(abandonStartup: true)
        #expect(await waitUntil { await serviceA.isStopWaiting })

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value

        var failures: [AIProvider] = []
        manager.onRealtimeFailure = { _, provider, _ in failures.append(provider) }
        manager.setRealtimeHint("B-ACTIVE")
        await serviceB.emit("B-OWNER")
        #expect(await waitUntil { manager.fullText == "B-OWNER" })
        manager.sendAudio(Data([0xB0]))
        #expect(await waitUntil { await serviceB.sentAudio == [Data([0xB0])] })

        await serviceA.emit("STALE-A")
        await serviceA.failStream()
        await serviceA.releaseAudioSend(failing: true)
        await serviceA.releaseStop()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(manager.fullText == "B-OWNER")
        #expect(manager.realtimeError == "B-ACTIVE")
        #expect(failures.isEmpty)
        #expect(await serviceA.sentAudio.isEmpty)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func awaitFinalDeltasCommitsDeltaEmittedByProviderStop() async throws {
        let service = ControlledRealtimeService(finalTextOnStop: "FINAL-ON-STOP")
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake")
        }
        #expect(await waitUntil { await service.startCount == 1 })
        await service.completeHandshake()
        try await start.value

        await manager.stopRealtime(awaitFinalDeltas: true)

        #expect(manager.fullText == "FINAL-ON-STOP")
        #expect(manager.segments.map(\.text) == ["FINAL-ON-STOP"])
    }

    @Test func awaitFinalDeltasBlocksReplacementUntilExactSessionCloses() async throws {
        let serviceA = ControlledRealtimeService(blocksStop: true, finalTextOnStop: "A-FINAL")
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value

        let stopA = Task { @MainActor in
            await manager.stopRealtime(awaitFinalDeltas: true)
        }
        #expect(await waitUntil { await serviceA.isStopWaiting })

        var busyPhase: RealtimeSessionPhase?
        do {
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        } catch let error as RealtimeSessionBusyError {
            busyPhase = error.phase
        }
        #expect(busyPhase == .closing)
        #expect(await serviceB.startCount == 0)

        await serviceA.releaseStop()
        await stopA.value
        #expect(manager.fullText == "A-FINAL")

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value
        #expect(manager.realtimeProvider == .gemini)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func finalDrainDeadlineRetainsArrivedDeltaAndReleasesOwnerWhenStopHangs() async throws {
        let serviceA = ControlledRealtimeService(blocksStop: true, finalTextOnStop: "A-FINAL")
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(
            realtimeServiceFactory: factory.makeFactory(),
            realtimeFinalDrainTimeout: .milliseconds(60)
        )

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value

        let stopped = ControlledCompletionProbe()
        let stopA = Task { @MainActor in
            await manager.stopRealtime(awaitFinalDeltas: true)
            await stopped.complete()
        }
        #expect(await waitUntil { await serviceA.isStopWaiting })
        #expect(await waitUntil(timeout: .milliseconds(400)) { await stopped.isComplete })
        #expect(manager.fullText == "A-FINAL")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await serviceA.readyStopCount == 1)

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value
        await serviceB.emit("B-OWNER")
        #expect(await waitUntil { manager.fullText.contains("B-OWNER") })

        await serviceA.releaseStop()
        await stopA.value
        try? await Task.sleep(for: .milliseconds(30))
        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(manager.fullText.contains("B-OWNER"))
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func finalDrainDeadlineReleasesOwnerWhenProviderStreamNeverFinishes() async throws {
        let serviceA = ControlledRealtimeService(finishesStreamOnStop: false)
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(
            realtimeServiceFactory: factory.makeFactory(),
            realtimeFinalDrainTimeout: .milliseconds(60)
        )

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value

        let stopped = ControlledCompletionProbe()
        let stopA = Task { @MainActor in
            await manager.stopRealtime(awaitFinalDeltas: true)
            await stopped.complete()
        }
        #expect(await waitUntil { await serviceA.readyStopCount == 1 })
        #expect(await waitUntil(timeout: .milliseconds(400)) { await stopped.isComplete })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await serviceA.readyStopCount == 1)

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value
        await serviceB.emit("B-ONLY")
        #expect(await waitUntil { manager.fullText == "B-ONLY" })

        await serviceA.emit("STALE-A")
        await serviceA.finishStream()
        await stopA.value
        try? await Task.sleep(for: .milliseconds(30))
        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.fullText == "B-ONLY")
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func resetDuringFinalDrainLetsReplacementStartAndLateFinishCannotClearIt() async throws {
        let serviceA = ControlledRealtimeService(blocksStop: true, finalTextOnStop: "A-FINAL")
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let startA = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake-a")
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.completeHandshake()
        try await startA.value

        let stopA = Task { @MainActor in
            await manager.stopRealtime(awaitFinalDeltas: true)
        }
        #expect(await waitUntil { await serviceA.isStopWaiting })

        manager.reset()
        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value
        await serviceB.emit("B-OWNER")
        #expect(await waitUntil { manager.fullText == "B-OWNER" })

        #expect(await waitUntil { await serviceA.readyStopCount >= 2 })
        await serviceA.releaseStop()
        await stopA.value
        try? await Task.sleep(for: .milliseconds(30))

        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(manager.fullText == "B-OWNER")
        #expect(await serviceB.readyStopCount == 0)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func qualityComparisonConnectDeadlineBoundsNonCooperativeStartup() async throws {
        let serviceA = ControlledRealtimeService()
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        await #expect(throws: HardAsyncDeadlineExceeded.self) {
            try await QualityComparisonRunner.startRealtimeWithDeadline(
                manager: manager,
                provider: .openai,
                apiKey: "fake-a",
                language: "en",
                timeout: .milliseconds(60)
            )
        }
        #expect(await serviceA.startCount == 1)
        #expect(await serviceA.pendingStopCount >= 1)

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value

        // The orphaned A handshake may become ready after its caller timed out.
        // Manager ownership must close A again without touching live B.
        await serviceA.completeHandshake()
        #expect(await waitUntil { await serviceA.readyStopCount >= 1 })
        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(await serviceB.readyStopCount == 0)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func qualityConnectTimeoutCleanupCannotStopReplacementAttempt() async throws {
        let serviceA = ControlledRealtimeService(blocksStop: true)
        let serviceB = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let timedStartA = Task { @MainActor in
            try await QualityComparisonRunner.startRealtimeWithDeadline(
                manager: manager,
                provider: .openai,
                apiKey: "fake-a",
                language: "en",
                timeout: .milliseconds(120)
            )
        }
        #expect(await waitUntil { await serviceA.startCount == 1 })
        await serviceA.rejectHandshake()
        #expect(await waitUntil { await serviceA.isStopWaiting })

        let startB = Task { @MainActor in
            try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        }
        #expect(await waitUntil { await serviceB.startCount == 1 })
        await serviceB.completeHandshake()
        try await startB.value

        await #expect(throws: HardAsyncDeadlineExceeded.self) {
            try await timedStartA.value
        }
        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        #expect(await serviceB.readyStopCount == 0)

        await serviceA.releaseStop()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func qualityGeneralDeadlineDoesNotWaitForNonCooperativeWork() async {
        let gate = ControlledGate()
        defer { Task { await gate.release() } }

        let clock = ContinuousClock()
        let startedAt = clock.now
        await #expect(throws: HardAsyncDeadlineExceeded.self) {
            try await QualityComparisonRunner.runWithDeadline(
                timeout: .milliseconds(60)
            ) {
                await gate.wait()
            }
        }
        let elapsed = startedAt.duration(to: clock.now)
        #expect(elapsed < .milliseconds(300))
    }

    @Test func silentHealthyStreamSurvivesWatchdogWithoutFailure() async throws {
        let service = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(
            realtimeServiceFactory: factory.makeFactory(),
            realtimeWatchdogDelay: .milliseconds(40)
        )

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake")
        }
        #expect(await waitUntil { await service.startCount == 1 })
        await service.completeHandshake()
        try await start.value

        var failures: [AIProvider] = []
        manager.onRealtimeFailure = { _, provider, _ in failures.append(provider) }
        manager.sendAudio(Data([0x01]))
        #expect(await waitUntil { await service.sentAudio == [Data([0x01])] })

        // Silence: audio flows but the provider emits no deltas. The watchdog
        // must record a diagnostic and leave the healthy session alone.
        #expect(await waitUntil { manager.realtimeError != nil })
        try? await Task.sleep(for: .milliseconds(60))
        #expect(failures.isEmpty)
        #expect(manager.isTranscribing)

        // First speech clears the diagnostic and keeps the same session.
        await service.emit("HELLO")
        #expect(await waitUntil { manager.fullText == "HELLO" })
        #expect(manager.realtimeError == nil)
        #expect(failures.isEmpty)
        #expect(manager.isTranscribing)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func speechWithoutTextFailsTheWatchdog() async throws {
        let service = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(
            realtimeServiceFactory: factory.makeFactory(),
            realtimeWatchdogDelay: .milliseconds(40)
        )

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake")
        }
        #expect(await waitUntil { await service.startCount == 1 })
        await service.completeHandshake()
        try await start.value

        var failures: [AIProvider] = []
        manager.onRealtimeFailure = { _, provider, _ in failures.append(provider) }
        // The capture side reports speech in the watchdog window. Zero deltas
        // then means a half-open stream — the one failure mode that never
        // produces its own error event — so the watchdog must report it
        // instead of treating the quiet as silence.
        manager.realtimeAudioIsSilent = { false }
        manager.sendAudio(Data([0x01]))
        #expect(await waitUntil { await service.sentAudio == [Data([0x01])] })

        #expect(await waitUntil { failures == [.openai] })
        #expect(manager.realtimeError != nil)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func firstContentDeltaReportsStreamHealthyExactlyOnce() async throws {
        let service = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake")
        }
        #expect(await waitUntil { await service.startCount == 1 })
        await service.completeHandshake()
        try await start.value

        var healthySignals = 0
        manager.onRealtimeStreamHealthy = { healthySignals += 1 }

        // Empty deltas are not content and must not report health.
        await service.emit("   ")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(healthySignals == 0)

        // An interim hypothesis is content too, but non-final deltas sit in
        // the stream task's batch buffer until a final delta flushes them, so
        // both arrive in one batch: FIRST reports health, FIRST-DONE must not.
        await service.emit("FIRST", isFinal: false)
        await service.emit("FIRST-DONE")
        #expect(await waitUntil { manager.fullText.contains("FIRST-DONE") })
        #expect(healthySignals == 1)

        await service.emit("SECOND")
        #expect(await waitUntil { manager.fullText.contains("SECOND") })
        #expect(healthySignals == 1)
        await manager.stopRealtime(abandonStartup: true)
    }

    @Test func watchdogFailureNoLongerTearsDownRealFaultReporting() async throws {
        // A genuine stream fault after the silent watchdog window must still
        // reach onRealtimeFailure through the stream task.
        let service = ControlledRealtimeService()
        let factory = RealtimeServiceFactorySpy([service])
        let manager = TranscriptionManager(
            realtimeServiceFactory: factory.makeFactory(),
            realtimeWatchdogDelay: .milliseconds(40)
        )

        let start = Task { @MainActor in
            try await manager.startRealtime(provider: .openai, apiKey: "fake")
        }
        #expect(await waitUntil { await service.startCount == 1 })
        await service.completeHandshake()
        try await start.value

        var failures: [AIProvider] = []
        manager.onRealtimeFailure = { _, provider, _ in failures.append(provider) }
        manager.sendAudio(Data([0x01]))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(failures.isEmpty)

        await service.failStream()
        #expect(await waitUntil { failures == [.openai] })
        manager.reset()
    }
}
