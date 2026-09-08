import Foundation
import Darwin
import Testing

@testable import Cadenza

@Suite("DebugDataRoot")
struct DebugDataRootTests {

    /// The test host sets no override, so every path must resolve exactly as
    /// it did before the seam existed. A relocation leaking into a normal run
    /// would point the suite at a throwaway directory.
    @Test func inactiveWithoutTheEnvironmentVariable() {
        #expect(ProcessInfo.processInfo.environment[DebugDataRoot.environmentKey] == nil)
        #expect(DebugDataRoot.url == nil)
        #expect(!DebugDataRoot.isActive)
        #expect(DebugDataRoot.applicationSupport == nil)
        #expect(DebugDataRoot.audioDirectory == nil)

        let realAppSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let realDocuments = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        #expect(DebugDataRoot.applicationSupportDirectory() == realAppSupport)
        #expect(DebugDataRoot.documentsDirectory() == realDocuments)
    }

    @Test func validationRequiresAbsoluteRootAndFixedHome() {
        #expect(DebugDataRoot.validate(environment: [:]) == .inactive)
        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: "relative/demo",
            DebugDataRoot.fixedUserHomeEnvironmentKey: "/tmp/demo/home",
        ]) == .invalid(reason: "CADENZA_DATA_ROOT must be an absolute path"))
        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: "/tmp/demo",
        ]) == .invalid(
            reason: "CFFIXED_USER_HOME is required when CADENZA_DATA_ROOT is set"
        ))
        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: "/tmp/demo",
            DebugDataRoot.fixedUserHomeEnvironmentKey: "relative/home",
        ]) == .invalid(reason: "CFFIXED_USER_HOME must be an absolute path"))
    }

    @Test func validationAcceptsOnlyCanonicalFixedHomesInsideTheRoot() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugDataRootTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("user-home", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let valid = DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: root.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: home.path,
        ])
        guard case .isolated(let canonicalRoot, let canonicalHome) = valid else {
            Issue.record("safe temporary fixture root was rejected")
            return
        }
        #expect(canonicalRoot.lastPathComponent == "root")
        #expect(canonicalHome == canonicalRoot
            .appendingPathComponent("user-home", isDirectory: true))

        let escapedByTraversal = DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: root.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: root
                .appendingPathComponent("..")
                .appendingPathComponent("outside")
                .path,
        ])
        #expect(escapedByTraversal == .invalid(
            reason: "CFFIXED_USER_HOME must resolve to a strict descendant of CADENZA_DATA_ROOT"
        ))

        let escapeLink = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        let escapedBySymlink = DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: root.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: escapeLink.path,
        ])
        #expect(escapedBySymlink == .invalid(
            reason: "CFFIXED_USER_HOME must resolve to a strict descendant of CADENZA_DATA_ROOT"
        ))
    }

    @Test func fixedHomeMustBeAnExistingIndependentSubdirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugDataRootHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: root.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: root.path,
        ]) == .invalid(
            reason: "CFFIXED_USER_HOME must resolve to a strict descendant of CADENZA_DATA_ROOT"
        ))

        let missingHome = root.appendingPathComponent("missing-home", isDirectory: true)
        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: root.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: missingHome.path,
        ]) == .invalid(
            reason: "CFFIXED_USER_HOME must resolve to an existing directory"
        ))
    }

    @Test func validConfigurationDerivesOnlyFixturePathsBelowTheRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugDataRootFixture-\(UUID().uuidString)", isDirectory: true)
        let fixedHome = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: fixedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: root.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: fixedHome.path,
        ])
        guard case .isolated(let acceptedRoot, _) = configuration else {
            Issue.record("valid fixture configuration was rejected")
            return
        }
        let expectedStore = acceptedRoot
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cadenza", isDirectory: true)
            .appendingPathComponent("Cadenza.store")
        #expect(expectedStore.path.hasPrefix(acceptedRoot.path + "/"))
    }

    @Test func validationRejectsNonexistentAndBroadFilesystemRoots() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugDataRootMissing-\(UUID().uuidString)", isDirectory: true)
        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: missingRoot.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: missingRoot.path,
        ]) == .invalid(reason: "CADENZA_DATA_ROOT must resolve to an existing directory"))

        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: "/",
            DebugDataRoot.fixedUserHomeEnvironmentKey: "/",
        ]) == .invalid(
            reason: "CADENZA_DATA_ROOT must be a strict descendant of an approved temporary directory"
        ))

        for temporaryRoot in DebugDataRoot.approvedTemporaryRoots() {
            #expect(DebugDataRoot.validate(environment: [
                DebugDataRoot.environmentKey: temporaryRoot.path,
                DebugDataRoot.fixedUserHomeEnvironmentKey: temporaryRoot.path,
            ]) == .invalid(
                reason: "CADENZA_DATA_ROOT must be a strict descendant of an approved temporary directory"
            ))
        }
    }

    @Test func validationRejectsPhysicalHomeLibraryAndRepository() throws {
        let physicalHome = try #require(DebugDataRoot.physicalHomeDirectory())
        let realLibrary = physicalHome.appendingPathComponent("Library", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: realLibrary.path))

        for unsafeRoot in [physicalHome, realLibrary] {
            let result = DebugDataRoot.validate(environment: [
                DebugDataRoot.environmentKey: unsafeRoot.path,
                DebugDataRoot.fixedUserHomeEnvironmentKey: unsafeRoot.path,
            ])
            #expect(result == .invalid(
                reason: "CADENZA_DATA_ROOT must not resolve inside the physical user home"
            ))
        }

        for repositoryLocation in [repositoryRoot(), repositoryRoot()
            .appendingPathComponent("Cadenza", isDirectory: true)] {
            let result = DebugDataRoot.validate(environment: [
                DebugDataRoot.environmentKey: repositoryLocation.path,
                DebugDataRoot.fixedUserHomeEnvironmentKey: repositoryLocation.path,
            ])
            #expect(result == .invalid(
                reason: "CADENZA_DATA_ROOT must not resolve inside the source repository"
            ))
        }
    }

    @Test func validationRejectsRootSymlinkEscapeAndPrefixConfusion() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugDataRootEscape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let physicalHome = try #require(DebugDataRoot.physicalHomeDirectory())
        let escapeRoot = container.appendingPathComponent("escape-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapeRoot, withDestinationURL: physicalHome)
        let escaped = DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: escapeRoot.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: escapeRoot.path,
        ])
        #expect(escaped == .invalid(
            reason: "CADENZA_DATA_ROOT must not resolve inside the physical user home"
        ))

        let canonicalTemporaryRoot = try #require(DebugDataRoot.approvedTemporaryRoots().first)
        let prefixConfusion = URL(
            fileURLWithPath: canonicalTemporaryRoot.path + "-lookalike/fixture",
            isDirectory: true
        )
        #expect(!DebugDataRoot.isStrictDescendant(
            root: canonicalTemporaryRoot,
            candidate: prefixConfusion
        ))
    }

    @Test func validationRejectsGroupOrWorldWritableFixtureRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugDataRootWritable-\(UUID().uuidString)", isDirectory: true)
        let fixedHome = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: fixedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(chmod(root.path, 0o777) == 0)

        #expect(DebugDataRoot.validate(environment: [
            DebugDataRoot.environmentKey: root.path,
            DebugDataRoot.fixedUserHomeEnvironmentKey: fixedHome.path,
        ]) == .invalid(
            reason: "CADENZA_DATA_ROOT must be owned by the current user and not group/world-writable"
        ))
    }

    @Test func anyExplicitConfigurationBlocksLiveCredentialAccess() {
        let root = URL(fileURLWithPath: "/private/tmp/fixture", isDirectory: true)
        #expect(!DebugDataRoot.blocksLiveAccess(configuration: .inactive))
        #expect(DebugDataRoot.blocksLiveAccess(configuration: .invalid(reason: "unsafe")))
        #expect(DebugDataRoot.blocksLiveAccess(configuration: .isolated(
            root: root,
            fixedUserHome: root.appendingPathComponent("home", isDirectory: true)
        )))
    }

    /// Every filesystem entry point for user data routes through
    /// `DebugDataRoot`. A direct search-path call added elsewhere relocates
    /// only part of the data plane, which is strictly worse than relocating
    /// none: an instance reading a fixture store while resolving the real
    /// audio root will scan — and import from — the user's recordings.
    ///
    /// The exemptions are deliberate, not grandfathered:
    /// - `DebugDataRoot` itself is the fallback.
    /// - `StorageLocationManager.defaultDirectory` holds the non-relocated
    ///   branch of that same decision.
    /// - `WhisperModelManager` caches large read-only models that carry no
    ///   user content; a relocated instance shares them by design.
    @Test func userDataPathsRouteThroughTheSeam() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Cadenza", isDirectory: true)
            .resolvingSymlinksInPath()
        let exempt: Set<String> = [
            "DebugDataRoot.swift",
            "StorageLocationManager.swift",
            "WhisperModelManager.swift",
            // The stdio bridge is a separate process (the `cadenza-mcp` tool
            // target does not compile DebugDataRoot) and must find the app's
            // endpoint file at the real Application Support location.
            "MCPBridgeRuntime.swift",
        ]
        // Match the search-path argument, not the bare enum case: the seam's
        // own accessors are named after these directories.
        let searchPaths = ["for: .applicationSupportDirectory", "for: .documentDirectory"]

        let enumerator = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !exempt.contains(url.lastPathComponent) else { continue }
            scanned += 1
            let contents = try String(contentsOf: url, encoding: .utf8)
            for path in searchPaths {
                #expect(
                    !contents.contains(path),
                    """
                    \(url.lastPathComponent) resolves \(path) directly. \
                    Route it through DebugDataRoot, or add a documented exemption.
                    """
                )
            }
        }
        #expect(scanned >= 50)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }
}

@Suite("Isolated Keychain")
struct IsolatedKeychainTests {
    @Test func isolatedManagerNeverConstructsOrInspectsLiveStores() throws {
        let live = TrackingKeychainStore(values: [
            "apiKey.openai": "seeded-live-key",
            "oauth.tokens.notion": "seeded-live-token",
        ])
        let legacy = TrackingKeychainStore(values: [
            "apiKey.openai": "seeded-legacy-key",
        ])
        var primaryFactoryCalls = 0
        var legacyFactoryCalls = 0
        let manager = KeychainManager(
            isolated: true,
            livePrimaryStore: {
                primaryFactoryCalls += 1
                return live
            },
            liveLegacyStore: { _ in
                legacyFactoryCalls += 1
                return legacy
            }
        )

        #expect(manager.isMemoryOnly)
        #expect(primaryFactoryCalls == 0)
        #expect(manager.apiKey(for: .openai) == nil)
        #expect(manager.get("oauth.tokens.notion") == nil)

        try manager.setAPIKey("isolated-key", for: .openai)
        try manager.set("isolated-token", forKey: "oauth.tokens.notion")
        #expect(manager.apiKey(for: .openai) == "isolated-key")
        #expect(manager.get("oauth.tokens.notion") == "isolated-token")
        try manager.removeAPIKey(for: .openai)
        try manager.remove("oauth.tokens.notion")

        let defaults = UserDefaults(suiteName: "IsolatedKeychainTests.\(UUID().uuidString)")!
        defaults.set("persisted-default", forKey: "legacy.secret")
        #expect(manager.getWithMigration("legacy.secret", defaults: defaults).isEmpty)
        #expect(defaults.string(forKey: "legacy.secret") == "persisted-default")

        #expect(primaryFactoryCalls == 0)
        #expect(legacyFactoryCalls == 0)
        #expect(live.totalAccessCount == 0)
        #expect(legacy.totalAccessCount == 0)
        #expect(live.values["apiKey.openai"] == "seeded-live-key")
        #expect(legacy.values["apiKey.openai"] == "seeded-legacy-key")
    }

    @Test func liveManagerRetainsPrimaryAndLegacyBehavior() throws {
        let live = TrackingKeychainStore(values: ["generic": "primary"])
        let legacy = TrackingKeychainStore(values: ["apiKey.openai": "legacy-key"])
        let manager = KeychainManager(
            isolated: false,
            livePrimaryStore: { live },
            liveLegacyStore: { _ in legacy }
        )

        #expect(!manager.isMemoryOnly)
        #expect(manager.get("generic") == "primary")
        #expect(manager.apiKey(for: .openai) == "legacy-key")
        #expect(live.values["apiKey.openai"] == "legacy-key")
    }
}

private final class TrackingKeychainStore: KeychainValueStoring {
    var values: [String: String]
    private(set) var getCount = 0
    private(set) var setCount = 0
    private(set) var removeCount = 0

    var totalAccessCount: Int { getCount + setCount + removeCount }

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func get(_ key: String) throws -> String? {
        getCount += 1
        return values[key]
    }

    func set(_ value: String, key: String) throws {
        setCount += 1
        values[key] = value
    }

    func remove(_ key: String) throws {
        removeCount += 1
        values.removeValue(forKey: key)
    }
}
