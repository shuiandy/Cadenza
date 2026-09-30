import Foundation
import Testing
@testable import Cadenza

private actor ScriptedFinalsService: TranscriptionService {
    private var continuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func sendAudio(_ data: Data) async throws {}

    func stopRealtimeSession() async throws {
        continuation?.finish()
    }

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        throw TranscriptionError.notSupported("test-only realtime service")
    }

    func emitFinal(_ text: String) {
        continuation?.yield(TranscriptDelta(
            text: text,
            isFinal: true,
            language: nil,
            replacesHypothesis: true
        ))
    }
}

@Suite("Transcript spacing")
struct TranscriptSpacingTests {
    @Test(arguments: [
        ("units.", "We", "units. We"),
        ("我们开始吧。", "第一项", "我们开始吧。第一项"),
        ("会議を始めます。", "最初は", "会議を始めます。最初は"),
        ("시작합니다.", "첫 번째", "시작합니다. 첫 번째"),
        ("the report", ",", "the report,"),
        ("units. ", "We", "units. We"),
        ("", "We", "We"),
        ("don", "'t", "don't"),
        ("rock'", "n", "rock'n"),
        ("He said 'go.'", "Then", "He said 'go.' Then"),
        ("สวัสดี", "ครับ", "สวัสดีครับ"),
    ])
    func joiningFollowsTheScript(_ text: String, _ next: String, _ expected: String) {
        #expect(TranscriptSpacing.joining(text, next) == expected)
    }

    @MainActor
    @Test(arguments: [
        ("The thermal tests passed on all 12 units.", "We still need a supplier.",
         "The thermal tests passed on all 12 units. We still need a supplier."),
        ("我们开始吧。", "第一项是硬件进度。", "我们开始吧。第一项是硬件进度。"),
        ("회의를 시작합니다.", "첫 번째 안건입니다.", "회의를 시작합니다. 첫 번째 안건입니다."),
        ("Yes.", "Yes.", "Yes. Yes."),
        ("好的。", "好的。", "好的。好的。"),
    ])
    func adjacentFinalsJoinTheWayTheirScriptDoes(
        _ first: String,
        _ second: String,
        _ expected: String
    ) async throws {
        let service = ScriptedFinalsService()
        let manager = TranscriptionManager(realtimeServiceFactory: { _, _, _, _ in service })
        try await manager.startRealtime(
            provider: .gemini,
            apiKey: "fake",
            recordingStartTime: Date()
        )

        await service.emitFinal(first)
        await service.emitFinal(second)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while manager.segments.first?.text != expected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.segments.map(\.text) == [expected])
        #expect(manager.segments.allSatisfy { $0.isFinal })

        await manager.stopRealtime(abandonStartup: true)
    }
}
