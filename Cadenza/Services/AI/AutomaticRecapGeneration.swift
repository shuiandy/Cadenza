import Foundation

enum AutomaticRecapGeneration {
    static var defaultsKey: String { ActiveProfileDefaults.key("enableAutomaticRecaps") }

    /// Keeps the privacy boundary at the call site: no recap generator (and
    /// therefore no AI service) is invoked until the user explicitly opts in.
    @MainActor
    @discardableResult
    static func runIfEnabled(
        defaults: UserDefaults = .standard,
        operation: @MainActor () async -> Void
    ) async -> Bool {
        guard defaults.bool(forKey: defaultsKey) else { return false }
        await operation()
        return true
    }
}
