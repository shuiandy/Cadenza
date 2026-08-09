import Foundation
import Observation

/// Owns the provider-scoped value shown by a model override field.
///
/// The settings row changes its UserDefaults key when the selected provider
/// changes. Keeping that transition here prevents an old provider's visible
/// value from being written into the newly selected provider's key.
@MainActor @Observable
final class ModelOverrideFieldState {
    private(set) var text: String

    @ObservationIgnored private(set) var key: String
    @ObservationIgnored private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        text = Self.storedText(forKey: key, defaults: defaults)
    }

    var hasOverride: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func activate(key newKey: String) {
        guard newKey != key else { return }
        key = newKey
        text = Self.storedText(forKey: newKey, defaults: defaults)
    }

    func updateText(_ newValue: String) {
        text = newValue
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    func useRecommended() {
        text = ""
        defaults.removeObject(forKey: key)
    }

    private static func storedText(forKey key: String, defaults: UserDefaults) -> String {
        defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
