enum DetailLoadPhase: Sendable, Equatable {
    case loading
    case content
    case unavailable
}

/// Small value-type state machine for async detail fetches. Only the newest
/// request may publish a terminal result, so late callbacks cannot resurrect
/// deleted content or replace a newer screen state.
struct DetailLoadTracker: Sendable, Equatable {
    private var generation: UInt64 = 0
    private(set) var phase: DetailLoadPhase = .loading

    mutating func begin(hasContent: Bool) -> UInt64 {
        generation &+= 1
        if !hasContent {
            phase = .loading
        }
        return generation
    }

    @discardableResult
    mutating func finish(request: UInt64, found: Bool) -> Bool {
        guard request == generation else { return false }
        phase = found ? .content : .unavailable
        return true
    }
}
