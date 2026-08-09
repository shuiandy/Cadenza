import Testing

@testable import Cadenza

@Suite("Realtime overlay status")
struct RealtimeOverlayStatusTests {
    @Test func failureIsMutuallyExclusiveWithListeningAndActiveText() {
        #expect(
            RealtimeOverlayStatus.resolve(
                hint: "Authentication failed",
                segmentCount: 4,
                isEnabled: true
            ) == .failure("Authentication failed")
        )
    }

    @Test func activeSegmentsWinOverListening() {
        #expect(
            RealtimeOverlayStatus.resolve(
                hint: nil,
                segmentCount: 3,
                isEnabled: true
            ) == .active(segmentCount: 3)
        )
    }

    @Test func enabledEmptySessionListensAndDisabledSessionIsHidden() {
        #expect(RealtimeOverlayStatus.resolve(hint: nil, segmentCount: 0, isEnabled: true) == .listening)
        #expect(RealtimeOverlayStatus.resolve(hint: nil, segmentCount: 0, isEnabled: false) == .hidden)
    }

    @Test func blankHintDoesNotMaskLiveState() {
        #expect(
            RealtimeOverlayStatus.resolve(
                hint: "  \n",
                segmentCount: 1,
                isEnabled: true
            ) == .active(segmentCount: 1)
        )
    }
}
