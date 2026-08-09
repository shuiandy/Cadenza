import Foundation

/// Typed accessor for one profile's scoped preference keys
/// (`<key>.profile.<id>`, §4.3). All per-profile preference reads and
/// writes go through this scope; consumers holding it cannot accidentally
/// fall back to the global key.
struct ProfileDefaultsScope {
    let defaults: UserDefaults
    let profileID: UUID

    func scopedKey(_ base: String) -> String {
        ProfileScopedDefaults.scopedKey(base, profileID: profileID)
    }

    func object(forKey base: String) -> Any? {
        defaults.object(forKey: scopedKey(base))
    }

    func string(forKey base: String) -> String? {
        defaults.string(forKey: scopedKey(base))
    }

    func bool(forKey base: String) -> Bool {
        defaults.bool(forKey: scopedKey(base))
    }

    func integer(forKey base: String) -> Int {
        defaults.integer(forKey: scopedKey(base))
    }

    func data(forKey base: String) -> Data? {
        defaults.data(forKey: scopedKey(base))
    }

    func stringArray(forKey base: String) -> [String]? {
        defaults.stringArray(forKey: scopedKey(base))
    }

    func set(_ value: Any?, forKey base: String) {
        defaults.set(value, forKey: scopedKey(base))
    }

    func removeObject(forKey base: String) {
        defaults.removeObject(forKey: scopedKey(base))
    }
}

/// Resolved execution context for the active profile (INV-5): the sole
/// authority for store location, session storage, and scoped preferences.
/// Constructed exactly once at startup, after the registry is read and
/// before any auth or sync service exists (§5.3) — code that needs session
/// or store access receives this context; nothing reads a global fallback.
struct ProfileContext {
    /// Registry snapshot of the profile at boot. Durable mutations go
    /// through the registry; this copy answers identity/binding questions
    /// for the lifetime of the process (switching profiles = relaunch).
    let profile: Profile
    let paths: ProfilePaths
    let scopedDefaults: ProfileDefaultsScope

    init(profile: Profile, paths: ProfilePaths, defaults: UserDefaults = .standard) {
        self.profile = profile
        self.paths = paths
        self.scopedDefaults = ProfileDefaultsScope(defaults: defaults, profileID: profile.id)
    }

    var profileID: UUID { profile.id }
    var storeURL: URL { paths.storeURL(profile.id) }
    var sessionUserURL: URL { paths.sessionUserURL(profile.id) }
    var chatHistoryDirectory: URL { paths.chatHistoryDirectory(profile.id) }
    var backupsDirectory: URL { paths.backupsDirectory(profile.id) }

    /// Keychain account for this profile's token, derived from the bound
    /// origin. Nil for unbound profiles — there is no token slot until a
    /// binding fixes the issuer (INV-7).
    var tokenAccount: String? {
        guard let bound = profile.boundAccount,
              let origin = try? IssuerOrigin(validating: bound.issuerOrigin) else {
            return nil
        }
        return SessionTokenKey.account(profileID: profile.id, originKey: origin.originKey)
    }

    func makeSessionUserStore(fileOperations: FileOperations) -> FileSessionUserStore {
        FileSessionUserStore(url: sessionUserURL, fileOperations: fileOperations)
    }
}

/// Startup resolution of which profile the process runs as (§5.3, INV-1):
/// a locked or missing active profile falls back to the system Local
/// profile; a registry with no usable profile at all is unresolvable and
/// the boot halts rather than guessing.
enum ActiveProfileResolution: Equatable {
    case active(Profile)
    case fallbackToLocal(Profile, reason: String)
    case unresolvable(reason: String)

    static func resolve(document: ProfileRegistryDocument) -> ActiveProfileResolution {
        let systemLocal = document.profiles.first { $0.kind == .system }
        let designated = document.profiles.first { $0.id == document.activeProfileID }

        if let profile = designated, !profile.isLocked {
            return .active(profile)
        }
        let reason = designated == nil
            ? "active profile missing from registry"
            : "active profile is locked"
        guard let local = systemLocal else {
            return .unresolvable(reason: "\(reason); no system Local profile exists")
        }
        if local.isLocked {
            return .unresolvable(reason: "\(reason); system Local profile is locked")
        }
        return .fallbackToLocal(local, reason: reason)
    }
}
