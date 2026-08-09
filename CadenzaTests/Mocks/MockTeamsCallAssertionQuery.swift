import Foundation
@testable import Cadenza

final class MockTeamsCallAssertionQuery: TeamsCallAssertionQuerying {
    var defaultState: TeamsCallAssertionState = .inactive
    var statesByProcessID: [pid_t: TeamsCallAssertionState] = [:]
    private(set) var requestedProcessIDs: [pid_t] = []

    func state(for processIDs: [pid_t]) -> TeamsCallAssertionState {
        requestedProcessIDs.append(contentsOf: processIDs)
        let states = processIDs.map { statesByProcessID[$0] ?? defaultState }
        if states.contains(.active) { return .active }
        if states.contains(.unavailable) { return .unavailable }
        return .inactive
    }
}
