import Foundation
import Testing
@testable import Cadenza

/// The user-facing promise these lock down: a setting you turned on in a
/// profile survives every later app launch and every re-run of the defaults
/// mapping. The mapping seeds scoped keys from their pre-profile globals; it is
/// not a sync, and it must never take a value back.
@Suite("Scoped defaults are never destructive")
struct ScopedDefaultsNonDestructiveTests {
    private func makeScope() -> (UserDefaults, ProfileScopedDefaults, String) {
        let suiteName = "scoped-nondestructive-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (
            defaults,
            ProfileScopedDefaults(defaults: defaults, persistentDomainName: suiteName),
            suiteName
        )
    }

    /// The exact upgrade hazard: the app stops writing a global key, a later
    /// release bumps the mapping marker so the copy re-runs for every profile,
    /// and the user's per-profile value must still be there afterwards.
    @Test func aReRunAfterTheGlobalIsGoneKeepsTheUserValue() {
        let (defaults, scoped, suiteName) = makeScope()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        let key = ProfileScopedDefaults.scopedKey("markdownMirrorEnabled", profileID: profileID)

        defaults.set(true, forKey: "markdownMirrorEnabled")
        scoped.copyGlobalValues(to: profileID)
        #expect(defaults.object(forKey: key) as? Bool == true)

        // The global is gone and the marker was reset — exactly what a version
        // bump of `mappingMarkerKey` produces for an existing install.
        defaults.removeObject(forKey: "markdownMirrorEnabled")
        defaults.removeObject(
            forKey: ProfileScopedDefaults.scopedKey(
                ProfileScopedDefaults.mappingMarkerKey, profileID: profileID
            )
        )
        #expect(!scoped.mappingComplete(for: profileID))
        scoped.copyGlobalValues(to: profileID)

        #expect(defaults.object(forKey: key) as? Bool == true)
        #expect(scoped.mappingComplete(for: profileID))
    }

    /// A scoped value the user changed after the first mapping must win over the
    /// stale global it was seeded from.
    @Test func aReRunNeverOverwritesAUserEditedValue() {
        let (defaults, scoped, suiteName) = makeScope()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        let key = ProfileScopedDefaults.scopedKey("userName", profileID: profileID)

        defaults.set("Seeded", forKey: "userName")
        scoped.copyGlobalValues(to: profileID)
        #expect(defaults.object(forKey: key) as? String == "Seeded")

        defaults.set("Edited in this profile", forKey: key)
        scoped.copyGlobalValues(to: profileID)
        #expect(defaults.object(forKey: key) as? String == "Edited in this profile")
    }

    /// Seeding still refuses to invent values: absent globally and absent
    /// scoped means the key stays absent, so registered defaults keep applying.
    @Test func absentEverywhereStaysAbsent() {
        let (defaults, scoped, suiteName) = makeScope()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()

        scoped.copyGlobalValues(to: profileID)

        for base in ["userJobTitle", "notion.databaseID", "enableAutomaticRecaps"] {
            #expect(
                defaults.object(
                    forKey: ProfileScopedDefaults.scopedKey(base, profileID: profileID)
                ) == nil
            )
        }
    }

    /// One profile's re-run must not reach into another profile's values.
    @Test func aReRunTouchesOnlyItsOwnProfile() {
        let (defaults, scoped, suiteName) = makeScope()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = UUID()
        let second = UUID()
        let secondKey = ProfileScopedDefaults.scopedKey("userName", profileID: second)

        defaults.set("Global", forKey: "userName")
        defaults.set("Second profile only", forKey: secondKey)
        scoped.copyGlobalValues(to: first)

        #expect(
            defaults.object(
                forKey: ProfileScopedDefaults.scopedKey("userName", profileID: first)
            ) as? String == "Global"
        )
        #expect(defaults.object(forKey: secondKey) as? String == "Second profile only")
    }
}
