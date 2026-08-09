import Foundation
import os

/// Process-wide key resolution for the active profile's scoped preferences
/// (§4.3). The boot activates exactly one explicit mode before any
/// consumer runs; afterwards every inventoried preference key resolves to
/// its scoped twin `<key>.profile.<id>` — profile mode never reads or
/// writes the global key. Intended for SwiftUI `@AppStorage` sites and
/// key-constant consumers; services that take injected dependencies
/// receive the resolver explicitly.
enum ActiveProfileDefaults {
    enum Mode: Equatable, Sendable {
        /// Nothing resolved yet. Resolving a key in this state is
        /// programmer error in the live app (activation precedes every
        /// consumer) and fails closed with a crash instead of silently
        /// reading globals. TestHost and previews resolve as `ephemeral`.
        case unresolved
        case profile(UUID)
        /// Pre-commit legacy fallback: an explicit passthrough to the
        /// global keys the legacy boot keeps using.
        case legacyFallback
        /// TestHost / preview passthrough — never the live app.
        case ephemeral
    }

    enum ActivationResult: Equatable {
        case activated
        case alreadyActive
        case conflict(Mode)
    }

    /// Activation is a validated one-way transition: the resolved identity
    /// binds the whole process (container, auth, coordinators), so a
    /// different second activation would mean an in-process profile switch
    /// — structurally forbidden; switching relaunches (§7).
    static func transitionResult(from current: Mode, to newMode: Mode) -> ActivationResult {
        if current == newMode { return .alreadyActive }
        if current == .unresolved { return .activated }
        return .conflict(current)
    }

    private static let state = OSAllocatedUnfairLock<Mode>(initialState: .unresolved)

    static var mode: Mode { state.withLock { $0 } }

    /// Registered defaults for the value-typed inventoried keys; the
    /// activation re-registers them under the scoped twins so code
    /// defaults survive the key mapping.
    static var scopedRegisteredDefaults: [String: Any] {
        [
            "autoExportToNotion": false,
            "autoExportToCraft": false,
            "enableAutomaticRecaps": false,
            "meetingPrepEnabled": false,
            "meetingPrepLeadMinutes": 30,
        ]
    }

    /// Boot-time activation for profile mode.
    static func activate(profileID: UUID, defaults: UserDefaults = .standard) {
        transition(to: .profile(profileID))
        var scoped: [String: Any] = [:]
        for (key, value) in scopedRegisteredDefaults {
            scoped[ProfileScopedDefaults.scopedKey(key, profileID: profileID)] = value
        }
        defaults.register(defaults: scoped)
    }

    /// Boot-time activation for the pre-commit legacy fallback: global
    /// keys stay operative, as an explicit recorded decision.
    static func activateLegacyFallback() {
        transition(to: .legacyFallback)
    }

    /// Explicit TestHost / preview activation from the startup path.
    static func activateEphemeral() {
        transition(to: .ephemeral)
    }

    private static func transition(to newMode: Mode) {
        let result = state.withLock { current in
            let result = transitionResult(from: current, to: newMode)
            if result == .activated { current = newMode }
            return result
        }
        if case .conflict(let existing) = result {
            preconditionFailure(
                "profile defaults already activated as \(existing); switching requires relaunch"
            )
        }
    }

    static func key(_ base: String) -> String {
        var current = mode
        if current == .unresolved, isTestOrPreview {
            // Previews construct views without the boot; the TestHost boot
            // activates ephemeral explicitly and this lands on the same
            // one-way state, never a silent passthrough.
            transition(to: .ephemeral)
            current = .ephemeral
        }
        guard let resolved = resolvedKey(base, mode: current) else {
            preconditionFailure("preference key resolved before profile activation")
        }
        return resolved
    }

    /// Pure resolution used by `key` and its tests: nil means fail-closed —
    /// an unresolved state never yields the global key.
    static func resolvedKey(_ base: String, mode: Mode) -> String? {
        switch mode {
        case .profile(let id):
            return ProfileScopedDefaults.scopedKey(base, profileID: id)
        case .legacyFallback, .ephemeral:
            return base
        case .unresolved:
            return nil
        }
    }

    private static var isTestOrPreview: Bool {
        AppState.isRunningTests
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

#if DEBUG
    /// Test seam for the mapping tests; callers must restore the previous
    /// mode so parallel suites never observe a leaked activation.
    static func overrideForTesting(_ newMode: Mode) -> Mode {
        state.withLock { current in
            let previous = current
            current = newMode
            return previous
        }
    }
#endif
}
