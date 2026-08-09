struct CalendarRefreshGate: Sendable, Equatable {
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}
