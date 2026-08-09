import Foundation
import Testing

@testable import Cadenza

/// Acceptance gate for the path resolution layer: the raw path column names
/// may only appear at the store boundary. Everything else consumes
/// `AudioFileReference` through DTOs and resolves URLs via
/// `ProfileStorageResolver` — a new call site that touches the raw string
/// turns this red.
@Suite("Audio Reference Seal")
struct AudioReferenceSealTests {

    /// Files that legitimately name the columns: the model that declares
    /// them, and the store files whose #Predicate / propertiesToFetch /
    /// boundary conversions physically require the stored property.
    private static let allowedFiles: Set<String> = [
        "Cadenza/Models/Recording.swift",
        "Cadenza/Services/Persistence/RecordingsStore.swift",
        "Cadenza/Services/Persistence/RecordingsStore+Archive.swift",
    ]

    @Test func rawPathColumnsOnlyAppearAtTheStoreBoundary() throws {
        // Canonicalized: when the checkout sits under a symlinked path
        // (/tmp vs /private/tmp), the #filePath spelling and the
        // enumerator's URL spelling diverge and prefix stripping breaks.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let productionRoot = repoRoot.appendingPathComponent("Cadenza", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(
            at: productionRoot, includingPropertiesForKeys: [.isRegularFileKey]
        ))

        // Word-boundary match: `audioSegmentsDirectoryURL` (the resolved
        // form on boundary structs) is legitimate everywhere.
        let columns = try Regex(#"\baudioFilePath\b|\baudioSegmentsDirectory\b"#)
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let relative = url.resolvingSymlinksInPath().path
                .replacingOccurrences(of: repoRoot.path + "/", with: "")
            #expect(!relative.hasPrefix("/"), "prefix stripping failed for \(relative)")
            guard !Self.allowedFiles.contains(relative) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(columns) {
                Issue.record("raw path column referenced outside the store boundary: \(relative)")
            }
        }
        #expect(scanned > 100, "production source scan looks incomplete (\(scanned) files)")
    }

    /// Test stores must scope their audio root to a per-test directory. The
    /// filesystem root would authorize deletion and cleanup across the whole
    /// disk and turns the strict-relative write contract into "any absolute
    /// path is valid".
    @Test func testAudioRootsNeverUseTheFilesystemRoot() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let testsRoot = repoRoot.appendingPathComponent("CadenzaTests", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(
            at: testsRoot, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        // Assembled so this file's own source does not match itself.
        let forbidden = "setAudioRootForTesting(URL(fileURLWithPath: " + "\"/\"))"
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(forbidden) {
                Issue.record("filesystem-root audio override in \(url.lastPathComponent)")
            }
        }
    }

    /// The runtime guard is the primary defense (the source scan above is
    /// spelling-sensitive): the validity predicate must reject every
    /// spelling of the filesystem root and accept scoped directories.
    @Test func audioRootValidityPredicateRejectsTheFilesystemRoot() {
        #expect(!RecordingsStore.isValidTestAudioRoot(URL(fileURLWithPath: "/")))
        #expect(!RecordingsStore.isValidTestAudioRoot(URL(fileURLWithPath: "//")))
        #expect(!RecordingsStore.isValidTestAudioRoot(URL(filePath: "/")))
        #expect(RecordingsStore.isValidTestAudioRoot(FileManager.default.temporaryDirectory))
        #expect(RecordingsStore.isValidTestAudioRoot(URL(fileURLWithPath: "/tmp")))
    }
}
