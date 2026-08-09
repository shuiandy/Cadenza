import Foundation
import Testing
@testable import Cadenza

@Suite("Model Override Field State")
struct ModelOverrideFieldStateTests {
    @MainActor @Test func switchingProviderLoadsItsStoredOverride() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gpt-5.4", forKey: "model.openai")
        defaults.set("gemini-3.5-flash", forKey: "model.gemini")

        let state = ModelOverrideFieldState(key: "model.openai", defaults: defaults)
        #expect(state.text == "gpt-5.4")

        state.activate(key: "model.gemini")

        #expect(state.key == "model.gemini")
        #expect(state.text == "gemini-3.5-flash")
    }

    @MainActor @Test func switchingToUnsetProviderDoesNotCopyOldValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gpt-5.4", forKey: "model.openai")

        let state = ModelOverrideFieldState(key: "model.openai", defaults: defaults)
        state.activate(key: "model.gemini")

        #expect(state.text.isEmpty)
        #expect(defaults.object(forKey: "model.gemini") == nil)
        #expect(defaults.string(forKey: "model.openai") == "gpt-5.4")
    }

    @MainActor @Test func editingWritesOnlyTheActiveProviderKey() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gpt-5.4", forKey: "model.openai")

        let state = ModelOverrideFieldState(key: "model.openai", defaults: defaults)
        state.activate(key: "model.gemini")
        state.updateText("  gemini-3.5-flash  ")

        #expect(defaults.string(forKey: "model.gemini") == "gemini-3.5-flash")
        #expect(defaults.string(forKey: "model.openai") == "gpt-5.4")
    }

    @MainActor @Test func useRecommendedRemovesOnlyTheActiveOverride() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gpt-custom", forKey: "model.openai")
        defaults.set("gemini-custom", forKey: "model.gemini")

        let state = ModelOverrideFieldState(key: "model.gemini", defaults: defaults)
        state.useRecommended()

        #expect(state.text.isEmpty)
        #expect(!state.hasOverride)
        #expect(defaults.object(forKey: "model.gemini") == nil)
        #expect(defaults.string(forKey: "model.openai") == "gpt-custom")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ModelOverrideFieldStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
