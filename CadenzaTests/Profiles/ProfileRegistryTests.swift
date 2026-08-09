import Foundation
import Testing

@testable import Cadenza

/// Registry document round-trip, atomic write behavior, explicit-null
/// pending fields, epoch date persistence, forward-compatible decoding,
/// the malformed-document error path, and in-memory registry parity.
@Suite("Profile Registry")
struct ProfileRegistryTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRegistry(in dir: URL) -> DiskProfileRegistry {
        DiskProfileRegistry(
            registryURL: dir.appendingPathComponent("profiles.json"),
            fileOperations: LiveFileOperations()
        )
    }

    private func makePendingBinding(profileID: UUID) throws -> PendingBinding {
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        return PendingBinding(
            transactionID: UUID(),
            profileID: profileID,
            userID: "user-1",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            tokenDigest: SessionTokenDigest.digest(of: "token-1"),
            startedAt: Date(timeIntervalSince1970: 1_785_629_000.5)
        )
    }

    private func makeProfile(id: UUID = UUID()) -> Profile {
        Profile(
            id: id,
            kind: .standard,
            name: "Cadenza",
            colorHex: nil,
            createdAt: Date(timeIntervalSince1970: 1_785_628_800.5),
            lastActiveAt: Date(timeIntervalSince1970: 1_785_628_900),
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .userSelected),
            boundAccount: nil,
            lockOnSignOut: true,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )
    }

    @Test func roundTripsThroughDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = makeRegistry(in: dir)
        let profile = makeProfile()
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )

        #expect(registry.presence() == .absent)
        try registry.save(document)
        #expect(registry.presence() == .present)
        let loaded = try registry.load()
        #expect(loaded == document)
        // No temp residue from the atomic write.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".atomic-") }
        #expect(leftovers.isEmpty)
    }

    @Test func saveReplacesAtomicallyKeepingLatestDocument() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = makeRegistry(in: dir)
        let first = makeProfile()
        var document = ProfileRegistryDocument(
            version: 1, activeProfileID: first.id, profiles: [first]
        )
        try registry.save(document)
        document.profiles[0].name = "Renamed"
        try registry.save(document)

        #expect(try registry.load().profiles.first?.name == "Renamed")
    }

    /// The on-disk document always carries both pending keys — as explicit
    /// JSON null when no operation is mid-flight (spec §4.1) — and both
    /// round-trip with values set.
    @Test func pendingFieldsPersistAsExplicitNullAndRoundTripWithValues() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = makeRegistry(in: dir)
        let profile = makeProfile()
        var document = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        try registry.save(document)

        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("profiles.json"))
        ) as! [String: Any]
        #expect(raw["pendingBinding"] is NSNull)
        #expect(raw["pendingTransfer"] is NSNull)

        let second = makeProfile()
        document.profiles.append(second)
        document.pendingBinding = try makePendingBinding(profileID: profile.id)
        try registry.save(document)
        var loaded = try registry.load()
        #expect(loaded.pendingBinding == document.pendingBinding)

        // Binding and transfer are mutually exclusive; each round-trips
        // on its own. The transfer needs the legal writer shape: an
        // active system source and a freshly created bound target.
        var localSource = makeProfile()
        localSource.kind = .system
        localSource.name = "Local"
        var freshTarget = makeProfile()
        freshTarget.name = "Fresh"
        freshTarget.storeMaterialized = false
        freshTarget.createdByBindingTransactionID = UUID()
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        freshTarget.boundAccount = Profile.BoundAccount(
            userID: "transfer-user",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "t@example.com",
            displayName: "T",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
        var transferDocument = ProfileRegistryDocument(
            version: 1, activeProfileID: localSource.id,
            profiles: [localSource, freshTarget]
        )
        transferDocument.pendingTransfer = makeTestPendingTransfer(
            source: localSource, target: freshTarget, mode: .move
        )
        try registry.save(transferDocument)
        loaded = try registry.load()
        #expect(loaded.pendingBinding == nil)
        #expect(loaded.pendingTransfer == transferDocument.pendingTransfer)

        var both = transferDocument
        let bindTarget = makeProfile()
        both.profiles.append(bindTarget)
        both.pendingBinding = try makePendingBinding(profileID: bindTarget.id)
        #expect(throws: ProfileRegistryError.self) { try registry.save(both) }
    }

    /// Dates persist as epoch seconds (numbers, not strings) and round-trip
    /// exactly, including fractional seconds.
    @Test func datesPersistAsEpochSecondsAndRoundTripExactly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = makeRegistry(in: dir)
        let profile = makeProfile()
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        try registry.save(document)

        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("profiles.json"))
        ) as! [String: Any]
        let profiles = raw["profiles"] as! [[String: Any]]
        let createdAt = profiles[0]["createdAt"] as? NSNumber
        #expect(createdAt?.doubleValue == 1_785_628_800.5)

        let loaded = try registry.load()
        #expect(loaded.profiles.first?.createdAt == profile.createdAt)
        #expect(loaded.profiles.first?.lastActiveAt == profile.lastActiveAt)
    }

    /// A newer app may add fields; this version must still load the parts
    /// it knows (INV-16 forward direction).
    @Test func decodingToleratesUnknownFields() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profiles.json")
        let profile = makeProfile()
        var object = try JSONSerialization.jsonObject(
            with: ProfileRegistryCoding.makeEncoder().encode(ProfileRegistryDocument(
                version: 1, activeProfileID: profile.id, profiles: [profile]
            ))
        ) as! [String: Any]
        object["futureTopLevelField"] = ["nested": true]
        var profiles = object["profiles"] as! [[String: Any]]
        profiles[0]["futureProfileField"] = 42
        object["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try DiskProfileRegistry(
            registryURL: url, fileOperations: LiveFileOperations()
        ).load()
        #expect(loaded.profiles.first?.id == profile.id)
    }

    @Test func unsupportedVersionAndMalformedDocumentsThrow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profiles.json")
        let registry = DiskProfileRegistry(
            registryURL: url, fileOperations: LiveFileOperations()
        )

        // Missing file.
        #expect(throws: ProfileRegistryError.self) { try registry.load() }
        // Garbage bytes.
        try Data("not json".utf8).write(to: url)
        #expect(throws: ProfileRegistryError.self) { try registry.load() }
        // A future major version is not silently reinterpreted.
        let profile = makeProfile()
        var object = try JSONSerialization.jsonObject(
            with: ProfileRegistryCoding.makeEncoder().encode(ProfileRegistryDocument(
                version: 1, activeProfileID: profile.id, profiles: [profile]
            ))
        ) as! [String: Any]
        object["version"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: ProfileRegistryError.unsupportedVersion(99)) { try registry.load() }
    }

    /// The in-memory registry mirrors disk semantics — same coders, same
    /// validation — while never touching the filesystem.
    @Test func inMemoryRegistryMatchesDiskSemantics() throws {
        let registry = InMemoryProfileRegistry()
        #expect(registry.presence() == .absent)
        #expect(throws: ProfileRegistryError.self) { try registry.load() }

        let profile = makeProfile()
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        try registry.save(document)
        #expect(registry.presence() == .present)
        #expect(try registry.load() == document)

        var future = document
        future.version = 99
        #expect(throws: ProfileRegistryError.unsupportedVersion(99)) {
            try registry.save(future)
        }
    }

    /// Structural invariants are enforced on load AND save: version zero
    /// or negative, duplicate profile ids, a dangling activeProfileID,
    /// an empty profile list, and empty audio paths are all corruption.
    @Test func documentInvariantsRejectMalformedShapes() throws {
        let profile = makeProfile()
        let valid = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        let registry = InMemoryProfileRegistry()

        var versionZero = valid
        versionZero.version = 0
        #expect(throws: ProfileRegistryError.unsupportedVersion(0)) {
            try registry.save(versionZero)
        }
        var negative = valid
        negative.version = -3
        #expect(throws: ProfileRegistryError.unsupportedVersion(-3)) {
            try registry.save(negative)
        }
        var duplicate = valid
        duplicate.profiles = [profile, profile]
        #expect(throws: ProfileRegistryError.invariantViolated("duplicate profile ids")) {
            try registry.save(duplicate)
        }
        var danglingActive = valid
        danglingActive.activeProfileID = UUID()
        #expect(throws: ProfileRegistryError.invariantViolated("active profile missing")) {
            try registry.save(danglingActive)
        }
        var empty = valid
        empty.profiles = []
        #expect(throws: ProfileRegistryError.invariantViolated("no profiles")) {
            try registry.save(empty)
        }
        var emptyPath = valid
        emptyPath.profiles[0].audioDirectory.path = ""
        #expect(throws: ProfileRegistryError.invariantViolated("empty audio directory path")) {
            try registry.save(emptyPath)
        }

        // Pending-operation references must resolve inside the document.
        var danglingBinding = valid
        danglingBinding.pendingBinding = try makePendingBinding(profileID: UUID())
        #expect(throws: ProfileRegistryError.self) { try registry.save(danglingBinding) }
        var selfTransfer = valid
        selfTransfer.pendingTransfer = makeTestPendingTransfer(
            source: profile, target: profile, mode: .move
        )
        #expect(throws: ProfileRegistryError.self) { try registry.save(selfTransfer) }
        var danglingTransfer = valid
        var phantom = makeProfile()
        phantom.name = "Phantom"
        danglingTransfer.pendingTransfer = makeTestPendingTransfer(
            source: profile, target: phantom
        )
        #expect(throws: ProfileRegistryError.self) { try registry.save(danglingTransfer) }

        // Same invariants on the disk load path (file written raw).
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profiles.json")
        var object = try JSONSerialization.jsonObject(
            with: ProfileRegistryCoding.makeEncoder().encode(valid)
        ) as! [String: Any]
        object["version"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: ProfileRegistryError.unsupportedVersion(0)) {
            try DiskProfileRegistry(registryURL: url, fileOperations: LiveFileOperations()).load()
        }
    }

    /// A symlink at the registry path still counts as existing — presence
    /// marks a committed migration — but loading it fails closed instead
    /// of following the link.
    @Test func symlinkedRegistryExistsButFailsToLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let elsewhere = dir.appendingPathComponent("elsewhere.json")
        let profile = makeProfile()
        try ProfileRegistryCoding.makeEncoder().encode(ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )).write(to: elsewhere)
        let url = dir.appendingPathComponent("profiles.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)

        let registry = DiskProfileRegistry(registryURL: url, fileOperations: LiveFileOperations())
        #expect(registry.presence() == .present)
        #expect(throws: ProfileRegistryError.malformedDocument("not a regular file")) {
            try registry.load()
        }
    }

    @Test func ephemeralEnvironmentPathsLiveUnderItsBase() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-\(UUID().uuidString)", isDirectory: true)
        let environment = ProfileEnvironment.ephemeral(base: base)
        #expect(environment.isEphemeral)
        #expect(environment.paths.root.path.hasPrefix(base.path))
        #expect(environment.paths.registryURL.path.hasPrefix(base.path))
        let id = UUID()
        #expect(environment.paths.storeURL(id).path.hasPrefix(base.path))
        #expect(environment.paths.stagingDirectory(profileID: id).path.hasPrefix(base.path))
    }
}

// MARK: - Bound-account uniqueness (INV-2 backstop)

extension ProfileRegistryTests {
    /// One (originKey, userID) account may bind at most one profile;
    /// uniqueness is byte-keyed, so canonically equivalent but
    /// byte-distinct user IDs are different accounts and both valid.
    @Test func validateRejectsOneAccountBoundToTwoProfiles() throws {
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        func bound(userID: String) -> Profile.BoundAccount {
            Profile.BoundAccount(
                userID: userID,
                originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: "https://cadenzapp.com/api/v1",
                displayEmail: "a@b.com",
                displayName: "A",
                boundAt: Date(timeIntervalSince1970: 1_785_628_800)
            )
        }
        var first = makeProfile()
        first.boundAccount = bound(userID: "us\u{00E9}r-1")
        var second = makeProfile()
        second.name = "Second"
        second.boundAccount = bound(userID: "us\u{00E9}r-1")
        let registry = InMemoryProfileRegistry()

        let duplicate = ProfileRegistryDocument(
            version: 1, activeProfileID: first.id, profiles: [first, second]
        )
        #expect(throws: ProfileRegistryError.invariantViolated(
            "one account bound to multiple profiles"
        )) {
            try registry.save(duplicate)
        }

        second.boundAccount = bound(userID: "use\u{0301}r-1")
        let distinct = ProfileRegistryDocument(
            version: 1, activeProfileID: first.id, profiles: [first, second]
        )
        try registry.save(distinct)
        #expect(try registry.load() == distinct)
    }
}
