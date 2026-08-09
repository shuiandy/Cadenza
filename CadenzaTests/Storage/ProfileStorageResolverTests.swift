import Foundation
import Testing

@testable import Cadenza

/// Safety gates for the path resolution layer (spec §10.1): traversal and
/// symlink-escape rejection, canonical comparison across /var vs
/// /private/var spellings, lexical identity for symlinks, and verbatim
/// legacy resolution.
@Suite("Profile Storage Resolver")
struct ProfileStorageResolverTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    // MARK: - AudioFileReference classification

    @Test func classificationFollowsLeadingSlash() {
        #expect(AudioFileReference(storageValue: "/a/b.m4a") == .legacyAbsolute("/a/b.m4a"))
        #expect(AudioFileReference(storageValue: "b.m4a") == .relative("b.m4a"))
        #expect(AudioFileReference(storageValue: "segments/u1") == .relative("segments/u1"))
        #expect(AudioFileReference(storageValue: nil as String?) == nil)
        #expect(AudioFileReference(storageValue: "" as String?) == nil)
    }

    @Test func storageValueRoundTripsBothCases() {
        for value in ["/abs/x.m4a", "rel/x.m4a"] {
            #expect(AudioFileReference(storageValue: value).storageValue == value)
        }
    }

    @Test func codableUsesBareStringForm() throws {
        let refs: [AudioFileReference] = [.relative("a/b.m4a"), .legacyAbsolute("/c/d.m4a")]
        let data = try JSONEncoder().encode(refs)
        #expect(String(decoding: data, as: UTF8.self) == #"["a\/b.m4a","\/c\/d.m4a"]"#)
        let decoded = try JSONDecoder().decode([AudioFileReference].self, from: data)
        #expect(decoded == refs)
    }

    @Test func lastPathComponentNeedsNoRoot() {
        #expect(AudioFileReference.relative("segments/u1").lastPathComponent == "u1")
        #expect(AudioFileReference.legacyAbsolute("/a/b.m4a").lastPathComponent == "b.m4a")
    }

    // MARK: - Relative resolution

    @Test func resolvesRelativeInsideRoot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ProfileStorageResolver(root: root)

        let file = try resolver.resolveAudio(.relative("a.m4a"))
        #expect(file.lastPathComponent == "a.m4a")
        let nested = try resolver.resolveAudio(.relative("segments/u1"))
        #expect(nested.pathComponents.suffix(2) == ["segments", "u1"])
    }

    /// FileManager.temporaryDirectory is a /var/folders symlink into
    /// /private/var — the /var and /private/var spellings of the same root
    /// must resolve a reference to the same canonical URL, or one-sided
    /// canonicalization would reject every reference under temp roots.
    @Test func canonicalizationCoversSymlinkedTempRootSpelling() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let alternateSpelling: URL
        if root.path.hasPrefix("/private/var/") {
            alternateSpelling = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)))
        } else if root.path.hasPrefix("/var/") {
            alternateSpelling = URL(fileURLWithPath: "/private" + root.path)
        } else {
            return
        }
        let resolvedA = try ProfileStorageResolver(root: root)
            .resolveAudio(.relative("a.m4a"))
        let resolvedB = try ProfileStorageResolver(root: alternateSpelling)
            .resolveAudio(.relative("a.m4a"))
        #expect(resolvedA.path == resolvedB.path)
    }

    @Test func rejectsTraversalComponents() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ProfileStorageResolver(root: root)

        for bad in ["../outside.m4a", "a/../../outside.m4a", "./a.m4a", "a/./b.m4a"] {
            #expect(throws: ProfileStorageResolver.ResolutionError.self) {
                try resolver.resolveAudio(.relative(bad))
            }
        }
        #expect(throws: ProfileStorageResolver.ResolutionError.emptyReference) {
            try resolver.resolveAudio(.relative(""))
        }
    }

    @Test func rejectsSymlinkEscapingRoot() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try touch(outside.appendingPathComponent("secret.m4a"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        let resolver = ProfileStorageResolver(root: root)

        #expect(throws: ProfileStorageResolver.ResolutionError.self) {
            try resolver.resolveAudio(.relative("link/secret.m4a"))
        }
    }

    // MARK: - makeReference

    @Test func makeReferenceProducesRelativeForFilesUnderRoot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ProfileStorageResolver(root: root)
        let file = root.appendingPathComponent("segments/u1/seg0.m4a")
        try touch(file)

        let reference = try resolver.makeReference(for: file)
        #expect(reference == .relative("segments/u1/seg0.m4a"))
    }

    /// The same file addressed through the /var symlink spelling while the
    /// root uses /private/var (or vice versa) must still map to relative.
    @Test func makeReferenceBridgesSymlinkedSpellings() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.m4a")
        try touch(file)

        let alternateSpelling: URL
        if root.path.hasPrefix("/private/var/") {
            alternateSpelling = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)))
        } else if root.path.hasPrefix("/var/") {
            alternateSpelling = URL(fileURLWithPath: "/private" + root.path)
        } else {
            return
        }
        let resolver = ProfileStorageResolver(root: alternateSpelling)
        #expect(try resolver.makeReference(for: file) == .relative("a.m4a"))
    }

    @Test func makeReferenceRejectsOutsideRootAndRootItself() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let resolver = ProfileStorageResolver(root: root)

        #expect(throws: ProfileStorageResolver.ResolutionError.self) {
            try resolver.makeReference(for: outside.appendingPathComponent("x.m4a"))
        }
        #expect(throws: ProfileStorageResolver.ResolutionError.self) {
            try resolver.makeReference(for: root)
        }
    }

    // MARK: - Symlink identity

    /// A relative reference naming a symlink resolves to the link's lexical
    /// path, never the resolved target — deletion through the resolved URL
    /// must remove the link only.
    @Test func relativeResolutionReturnsTheLinkNotItsTarget() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.m4a")
        try touch(target)
        let alias = root.appendingPathComponent("alias.m4a")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let resolver = ProfileStorageResolver(root: root)

        let resolved = try resolver.resolveAudio(.relative("alias.m4a"))
        #expect(resolved.lastPathComponent == "alias.m4a")
        try FileManager.default.removeItem(at: resolved)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// makeReference stores the link's own subpath, not its target's.
    @Test func makeReferenceStoresTheLinkNotItsTarget() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.m4a")
        try touch(target)
        let alias = root.appendingPathComponent("alias.m4a")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let resolver = ProfileStorageResolver(root: root)

        #expect(try resolver.makeReference(for: alias) == .relative("alias.m4a"))
    }

    @Test func lexicalSubpathNeedsNoCanonicalResolvability() throws {
        let root = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let link = segments.appendingPathComponent("LINK")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let resolver = ProfileStorageResolver(root: root)

        // Canonical resolution rejects the escaping link…
        #expect(throws: ProfileStorageResolver.ResolutionError.self) {
            try resolver.resolveAudio(.relative("segments/LINK"))
        }
        // …but the lexical identity is still computable for coverage checks.
        #expect(resolver.lexicalSubpath(of: link) == "segments/LINK")
        #expect(resolver.lexicalSubpath(of: outside.appendingPathComponent("x.m4a")) == nil)
    }

    // MARK: - Legacy resolution

    /// Resolved URLs feed deletion, export, sync and playback — a basename
    /// probe in the current root would return another recording's file
    /// whenever two recordings share a filename. The resolver must return
    /// the original path even when it is missing and a same-named file
    /// exists in the root.
    @Test func legacyMissingNeverResolvesToSameNamedFileInRoot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent("same-name.m4a"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("segments/ABC-123", isDirectory: true),
            withIntermediateDirectories: true
        )
        let resolver = ProfileStorageResolver(root: root)

        let ghostFile = "/gone/old-root/same-name.m4a"
        #expect(try resolver.resolveAudio(.legacyAbsolute(ghostFile)).path == ghostFile)
        let ghostSegments = "/gone/old-root/segments/ABC-123"
        #expect(try resolver.resolveAudio(.legacyAbsolute(ghostSegments)).path == ghostSegments)
    }

    @Test func legacyResolvesVerbatimWhetherOrNotTheFileExists() throws {
        let root = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let existing = elsewhere.appendingPathComponent("real.m4a")
        try touch(existing)
        let resolver = ProfileStorageResolver(root: root)

        #expect(try resolver.resolveAudio(.legacyAbsolute(existing.path)).path == existing.path)
        let ghost = "/gone/forever/ghost.m4a"
        #expect(try resolver.resolveAudio(.legacyAbsolute(ghost)).path == ghost)
    }
}
