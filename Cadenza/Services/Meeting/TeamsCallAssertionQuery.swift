import Foundation
import IOKit.pwr_mgt

enum TeamsCallAssertionState: String, Equatable, Sendable {
    case active
    case inactive
    case unavailable
}

protocol TeamsCallAssertionQuerying {
    func state(for processIDs: [pid_t]) -> TeamsCallAssertionState
}

struct SystemTeamsCallAssertionQuery: TeamsCallAssertionQuerying {
    private static let assertionName = "Microsoft Teams Call in progress"

    func state(for processIDs: [pid_t]) -> TeamsCallAssertionState {
        guard !processIDs.isEmpty else { return .inactive }

        var unmanagedAssertions: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&unmanagedAssertions)
        guard status == kIOReturnSuccess,
              let assertionsByPID = unmanagedAssertions?.takeRetainedValue()
                as? [NSNumber: [[String: Any]]] else {
            return .unavailable
        }

        let isActive = processIDs.contains { processID in
            let assertions = assertionsByPID[NSNumber(value: processID)] ?? []
            return assertions.contains { assertion in
                guard assertion[kIOPMAssertionNameKey] as? String == Self.assertionName else {
                    return false
                }
                return (assertion[kIOPMAssertionLevelKey] as? NSNumber)?.intValue ?? 0 > 0
            }
        }
        return isActive ? .active : .inactive
    }
}
