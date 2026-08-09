import Foundation

/// Which data plane the process runs against (spec §8, INV-8).
///
/// `ProfileBootstrap.runLive` derives the live paths from this value and
/// refuses to proceed unless it is `.live`, so the environment decision is
/// on the production startup path, not a test convention. `.ephemeral` —
/// every test run — provides a unique temporary root for bootstrap tests;
/// the model container stays in-memory under the existing test rule.
enum ProfileEnvironment: Sendable, Equatable {
    case live
    case ephemeral(base: URL)

    static func current() -> ProfileEnvironment {
        if AppState.isRunningTests {
            return .ephemeral(
                base: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cadenza-ephemeral-\(UUID().uuidString)", isDirectory: true)
            )
        }
        return .live
    }

    var isEphemeral: Bool {
        if case .ephemeral = self { return true }
        return false
    }

    var paths: ProfilePaths {
        switch self {
        case .live:
            return ProfilePaths.live()
        case .ephemeral(let base):
            return ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        }
    }
}
