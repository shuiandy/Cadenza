import Darwin
import Foundation
import Testing
@testable import Cadenza

@Suite("Diagnostic artifact security boundary", .serialized)
struct DiagnosticArtifactStoreTests {
    @Test func appendRejectsSymlinkWithoutTouchingOutsideTarget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let outside = fixture.container.appendingPathComponent("outside.txt")
        try Data("outside-marker".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("meeting.log"),
            withDestinationURL: outside
        )

        #expect(throws: DiagnosticArtifactError.self) {
            try fixture.store.appendLog(
                named: "meeting.log",
                data: Data("sensitive".utf8),
                maximumBytes: 1_024
            )
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside-marker")
    }

    @Test func reportRejectsSymlinkWithoutTruncatingOutsideTarget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let outside = fixture.container.appendingPathComponent("outside-report.txt")
        try Data("outside-marker".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("system.txt"),
            withDestinationURL: outside
        )

        #expect(throws: DiagnosticArtifactError.self) {
            try fixture.store.writeReport(
                prefix: "system",
                contents: "sensitive",
                maximumBytes: 1_024
            )
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside-marker")
    }

    @Test func legacyCleanupUnlinksSymlinkWithoutTouchingTarget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let outside = fixture.container.appendingPathComponent("legacy-target.txt")
        let legacy = fixture.container.appendingPathComponent("legacy.log")
        try Data("outside-marker".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: outside)

        #expect(DiagnosticArtifactStore.removeLegacyOwnedArtifact(at: legacy))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside-marker")
    }

    @Test func legacyCleanupRemovesEveryFixedReportName() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        for name in DiagnosticArtifactStore.legacyReportNames {
            try Data("legacy-sensitive-report".utf8).write(
                to: fixture.container.appendingPathComponent(name)
            )
        }

        DiagnosticArtifactStore.removeLegacyArtifacts(
            temporaryDirectory: fixture.container,
            meetingLogURL: fixture.container.appendingPathComponent("legacy-meeting.log")
        )

        for name in DiagnosticArtifactStore.legacyReportNames {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.container.appendingPathComponent(name).path
            ))
        }
    }

    @Test func symlinkedRootAndNamedPipeFailClosed() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-root-\(UUID().uuidString)", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let linkedRoot = container.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: container) }

        let linkedStore = DiagnosticArtifactStore(rootDirectory: linkedRoot)
        #expect(throws: DiagnosticArtifactError.self) {
            try linkedStore.appendLog(
                named: "meeting.log",
                data: Data("sensitive".utf8),
                maximumBytes: 1_024
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("meeting.log").path
        ))

        let linkedParent = container.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        let descendantStore = DiagnosticArtifactStore(
            rootDirectory: linkedParent.appendingPathComponent("private", isDirectory: true)
        )
        #expect(throws: DiagnosticArtifactError.self) {
            try descendantStore.appendLog(
                named: "meeting.log",
                data: Data("sensitive".utf8),
                maximumBytes: 1_024
            )
        }

        let safeRoot = container.appendingPathComponent("safe-root", isDirectory: true)
        try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: false)
        let fifo = safeRoot.appendingPathComponent("meeting.log")
        #expect(Darwin.mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        let safeStore = DiagnosticArtifactStore(rootDirectory: safeRoot)
        #expect(throws: DiagnosticArtifactError.self) {
            try safeStore.appendLog(
                named: "meeting.log",
                data: Data("sensitive".utf8),
                maximumBytes: 1_024
            )
        }
    }

    @Test func sessionResetRemovesEveryKnownPrivateArtifact() throws {
        let fixture = try makeFixture(createRoot: false)
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        try fixture.store.appendLog(
            named: "meeting-detection.log",
            data: Data("meeting".utf8),
            maximumBytes: 1_024
        )
        for prefix in [
            "system-diagnostic",
            "functional-test",
            "quality-comparison",
            "speaker-memory",
        ] {
            _ = try fixture.store.writeReport(
                prefix: prefix,
                contents: "sensitive",
                maximumBytes: 1_024
            )
        }

        fixture.store.resetSessionArtifacts()

        for name in DiagnosticArtifactStore.sessionArtifactNames {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(name).path
            ))
        }
    }

    @Test func concurrentAppendsRemainWithinByteLimit() async throws {
        let fixture = try makeFixture(createRoot: false)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let payload = Data(repeating: 0x41, count: 32)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    try fixture.store.appendLog(
                        named: "meeting.log",
                        data: payload,
                        maximumBytes: 128
                    )
                }
            }
            try await group.waitForAll()
        }

        #expect(try fileSize(
            of: fixture.root.appendingPathComponent("meeting.log")
        ) <= 128)
    }

    @Test func appendCreatesPrivateBoundedArtifact() throws {
        let fixture = try makeFixture(createRoot: false)
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        try fixture.store.appendLog(
            named: "meeting.log",
            data: Data("first-entry".utf8),
            maximumBytes: 12
        )
        try fixture.store.appendLog(
            named: "meeting.log",
            data: Data("second-entry".utf8),
            maximumBytes: 12
        )

        let logURL = fixture.root.appendingPathComponent("meeting.log")
        let content = try String(contentsOf: logURL, encoding: .utf8)
        #expect(content == "second-entry")
        #expect(try permissions(of: fixture.root) == 0o700)
        #expect(try permissions(of: logURL) == 0o600)
        #expect(try fileSize(of: logURL) <= 12)
    }

    @Test func reportsReplacePrivateFileWithoutAccumulating() throws {
        let fixture = try makeFixture(createRoot: false)
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let first = try fixture.store.writeReport(
            prefix: "system",
            contents: "first",
            maximumBytes: 1_024
        )
        let second = try fixture.store.writeReport(
            prefix: "system",
            contents: "second",
            maximumBytes: 1_024
        )

        #expect(first == second)
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(try permissions(of: first) == 0o600)
        #expect(try permissions(of: second) == 0o600)
    }

    @Test func invalidNamesAndOversizedReportsFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        #expect(throws: DiagnosticArtifactError.self) {
            try fixture.store.appendLog(
                named: "../escape.log",
                data: Data("x".utf8),
                maximumBytes: 10
            )
        }
        #expect(throws: DiagnosticArtifactError.self) {
            try fixture.store.writeReport(
                prefix: "quality",
                contents: "too-large",
                maximumBytes: 3
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.container.appendingPathComponent("escape.log").path
        ))
    }

    private func makeFixture(
        createRoot: Bool = true
    ) throws -> (container: URL, root: URL, store: DiagnosticArtifactStore) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-artifacts-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        if createRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        return (container, root, DiagnosticArtifactStore(rootDirectory: root))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }

    private func fileSize(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int ?? -1
    }
}

@Suite("Bounded realtime diagnostic log")
struct RealtimeDebugLogTests {
    @Test func retainsOnlyBoundedTruncatedEntries() {
        let log = RealtimeDebugLog(maximumEntries: 3, maximumEntryBytes: 5)

        log.append("one-long")
        log.append("two-long")
        log.append("three-long")
        log.append("four-long")

        #expect(log.entries == ["two-l", "three", "four-"])
        log.clear()
        #expect(log.entries.isEmpty)
    }

    @Test func boundsUtf8BytesEvenForLargeGraphemeClusters() {
        let log = RealtimeDebugLog(maximumEntries: 1, maximumEntryBytes: 8)
        let oversizedCharacter = "e" + String(repeating: "\u{0301}", count: 20_000)

        log.append(oversizedCharacter)

        #expect((log.entries.first?.utf8.count ?? 0) <= 8)
    }
}

@Suite("Security scoped diagnostic access", .serialized)
@MainActor
struct SecurityScopedDiagnosticAccessTests {
    @Test func successfulAccessIsBalanced() async throws {
        let probe = SecurityScopedAccessProbe(startsSuccessfully: true)
        let value = await SecurityScopedResourceAccess.withAccess(
            to: URL(fileURLWithPath: "/tmp/audio.m4a"),
            start: probe.start,
            stop: probe.stop
        ) {
            "ok"
        }

        #expect(value == "ok")
        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 1)
    }

    @Test func thrownOperationStillStopsAccess() async {
        let probe = SecurityScopedAccessProbe(startsSuccessfully: true)

        await #expect(throws: SecurityScopedAccessTestError.self) {
            try await SecurityScopedResourceAccess.withAccess(
                to: URL(fileURLWithPath: "/tmp/audio.m4a"),
                start: probe.start,
                stop: probe.stop
            ) {
                throw SecurityScopedAccessTestError.expected
            }
        }

        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 1)
    }

    @Test func falseStartDoesNotCallStop() async throws {
        let probe = SecurityScopedAccessProbe(startsSuccessfully: false)

        _ = await SecurityScopedResourceAccess.withAccess(
            to: URL(fileURLWithPath: "/tmp/audio.m4a"),
            start: probe.start,
            stop: probe.stop
        ) {
            "ok"
        }

        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 0)
    }
}

@MainActor
private final class SecurityScopedAccessProbe {
    private let startsSuccessfully: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(startsSuccessfully: Bool) {
        self.startsSuccessfully = startsSuccessfully
    }

    func start(_ url: URL) -> Bool {
        _ = url
        startCount += 1
        return startsSuccessfully
    }

    func stop(_ url: URL) {
        _ = url
        stopCount += 1
    }
}

private enum SecurityScopedAccessTestError: Error {
    case expected
}
