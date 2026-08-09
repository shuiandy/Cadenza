import Darwin
import Foundation
import os
import Testing
@testable import Cadenza

private enum InjectedManifestWriteError: Error {
    case expected
}

private enum TaskOneValidation {
    case trusted(TrustedSegmentSet)
    case trustFailure

    var isTrustFailure: Bool {
        if case .trustFailure = self { return true }
        return false
    }
}

private struct SegmentManifestFixture {
    let scratchRoot: URL
    let authorityRoot: URL
    let recordingID: UUID
    let segmentsDirectory: URL

    static func make(
        relativeDirectory: [String]? = nil,
        recordingID: UUID = UUID()
    ) throws -> Self {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-trust-\(UUID().uuidString)", isDirectory: true)
        let authorityRoot = scratchRoot.appendingPathComponent("authorized", isDirectory: true)
        var segmentsDirectory = authorityRoot
        for component in relativeDirectory ?? ["segments", recordingID.uuidString] {
            segmentsDirectory.appendPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )
        return Self(
            scratchRoot: scratchRoot,
            authorityRoot: authorityRoot,
            recordingID: recordingID,
            segmentsDirectory: segmentsDirectory
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    func segmentURL(_ filename: String) -> URL {
        segmentsDirectory.appendingPathComponent(filename)
    }

    func writeFile(named filename: String, data: Data = Data([0x01, 0x02])) throws {
        let url = segmentURL(filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func writeManifest(
        recordingID manifestRecordingID: UUID? = nil,
        entries: [SegmentedAudioFileWriter.SegmentEntry],
        at url: URL? = nil,
        trailingWhitespaceBytes: Int = 0
    ) throws {
        let manifest = SegmentedAudioFileWriter.SegmentManifest(
            recordingID: (manifestRecordingID ?? recordingID).uuidString,
            segments: entries,
            isComplete: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(manifest)
        if trailingWhitespaceBytes > 0 {
            data.append(Data(repeating: 0x20, count: trailingWhitespaceBytes))
        }
        try data.write(to: url ?? segmentsDirectory.appendingPathComponent("segments.json"))
    }

    func writeValidManifest(segmentCount: Int = 2) throws {
        let entries = try (0..<segmentCount).map { index in
            let filename = segmentFilename(index)
            try writeFile(named: filename)
            return segmentEntry(index: index, filename: filename)
        }
        try writeManifest(entries: entries)
    }

    func request(
        suppliedSegmentURLs: [URL] = [],
        authorityRoot: URL? = nil
    ) -> RecordingAudioFinalizationRequest {
        RecordingAudioFinalizationRequest(
            origin: .crashRecovery,
            recordingID: recordingID,
            segmentsDirectory: segmentsDirectory,
            suppliedSegmentURLs: suppliedSegmentURLs,
            segmentStorageAuthority: SegmentStorageAuthority.authorize(
                root: authorityRoot ?? self.authorityRoot
            ),
            outputURL: scratchRoot.appendingPathComponent("output.m4a"),
            fallbackDuration: 30,
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            endDate: Date(timeIntervalSinceReferenceDate: 130),
            meetingTitle: nil
        )
    }
}

private actor TaskOneFinalizerSpy {
    private(set) var mergeCalls = 0
    private(set) var publishCalls = 0
    private(set) var storeCalls = 0
    private(set) var cleanupCalls = 0
    private(set) var postProcessCalls = 0

    func recordMerge() { mergeCalls += 1 }
    func recordPublish() { publishCalls += 1 }
    func recordStore() { storeCalls += 1 }
    func recordCleanup() { cleanupCalls += 1 }
    func recordPostProcess() { postProcessCalls += 1 }
}

private func segmentFilename(_ index: Int) -> String {
    String(format: "segment-%03d.m4a", index)
}

private func segmentEntry(
    index: Int,
    filename: String? = nil
) -> SegmentedAudioFileWriter.SegmentEntry {
    SegmentedAudioFileWriter.SegmentEntry(
        index: index,
        filename: filename ?? segmentFilename(index),
        startedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
        completedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index + 1))
    )
}

private func validateForTaskOne(
    _ fixture: SegmentManifestFixture,
    authorityRoot: URL? = nil
) async -> TaskOneValidation {
    guard let authority = SegmentStorageAuthority.authorize(
        root: authorityRoot ?? fixture.authorityRoot
    ) else { return .trustFailure }
    switch SegmentedAudioFileWriter.validateManifest(
        recordingID: fixture.recordingID,
        segmentsDirectory: fixture.segmentsDirectory,
        authority: authority
    ) {
    case .trusted(let trusted):
        return .trusted(trusted)
    case .trustFailure:
        return .trustFailure
    }
}

private func recheckForTaskOne(_ validation: TaskOneValidation) -> Bool {
    guard case .trusted(let trusted) = validation else { return false }
    return SegmentedAudioFileWriter.recheckForMerge(trusted)
}

private func readManifest(at directory: URL) throws -> SegmentedAudioFileWriter.SegmentManifest {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        SegmentedAudioFileWriter.SegmentManifest.self,
        from: Data(contentsOf: directory.appendingPathComponent("segments.json"))
    )
}

private func directoryInventory(at directory: URL) throws -> Set<String> {
    Set(
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
    )
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("SegmentedAudioFileWriter manifest durability", .serialized)
struct SegmentedAudioFileWriterDurabilityTests {
    @Test func initialManifestFailureThrowsAndLeavesNoActiveWriterOrSegment() async throws {
        let fixture = try SegmentManifestFixture.make()
        defer { fixture.remove() }
        let writeAttempts = OSAllocatedUnfairLock(initialState: 0)
        let writer = SegmentedAudioFileWriter(
            manifestDataWriter: { data, url in
                let attempt = writeAttempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 {
                    throw InjectedManifestWriteError.expected
                }
                try data.write(to: url, options: .atomic)
            }
        )

        #expect(throws: InjectedManifestWriteError.self) {
            try writer.startWriting(
                segmentsDir: fixture.segmentsDirectory,
                recordingID: fixture.recordingID
            )
        }

        #expect(writeAttempts.withLock { $0 } == 1)
        #expect(try directoryInventory(at: fixture.segmentsDirectory).isEmpty)
        #expect(await writer.stopWriting().isEmpty)

        // A second start must not be rejected as already active.
        try writer.startWriting(
            segmentsDir: fixture.segmentsDirectory,
            recordingID: fixture.recordingID
        )
        #expect(writeAttempts.withLock { $0 } == 2)
        #expect(
            try directoryInventory(at: fixture.segmentsDirectory) == [
                "segment-000.m4a",
                "segments.json",
            ]
        )
        #expect(await writer.stopWriting().count == 1)
    }

    @Test func failedRotationKeepsPreviousManifestAndRemovesUnlistedSegment() async throws {
        let fixture = try SegmentManifestFixture.make()
        defer { fixture.remove() }
        let writeAttempts = OSAllocatedUnfairLock(initialState: 0)
        let failureMessages = OSAllocatedUnfairLock(initialState: [String]())
        let writer = SegmentedAudioFileWriter(
            manifestDataWriter: { data, url in
                let attempt = writeAttempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 2 {
                    throw InjectedManifestWriteError.expected
                }
                try data.write(to: url, options: .atomic)
            }
        )
        writer.onWriterFailure = { message in
            failureMessages.withLock { $0.append(message) }
        }

        try writer.startWriting(
            segmentsDir: fixture.segmentsDirectory,
            recordingID: fixture.recordingID
        )
        let manifestURL = fixture.segmentsDirectory.appendingPathComponent("segments.json")
        let previousManifestData = try Data(contentsOf: manifestURL)
        let previousInventory = try directoryInventory(at: fixture.segmentsDirectory)

        writer.rotateSegmentForTesting()

        #expect(writeAttempts.withLock { $0 } == 2)
        #expect(failureMessages.withLock { $0.count } == 1)
        #expect(try Data(contentsOf: manifestURL) == previousManifestData)
        #expect(try directoryInventory(at: fixture.segmentsDirectory) == previousInventory)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.segmentURL("segment-001.m4a").path
        ))
        #expect(try readManifest(at: fixture.segmentsDirectory).segments.count == 1)

        #expect(await writer.stopWriting().count == 1)
        #expect(failureMessages.withLock { $0.count } == 1)
    }

    @Test func completionAndStopManifestFailuresReportOnceAndKeepRecoverableInventory() async throws {
        let fixture = try SegmentManifestFixture.make()
        defer { fixture.remove() }
        let writeAttempts = OSAllocatedUnfairLock(initialState: 0)
        let failureMessages = OSAllocatedUnfairLock(initialState: [String]())
        let writer = SegmentedAudioFileWriter(
            manifestDataWriter: { data, url in
                let attempt = writeAttempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt >= 3 {
                    throw InjectedManifestWriteError.expected
                }
                try data.write(to: url, options: .atomic)
            }
        )
        writer.onWriterFailure = { message in
            failureMessages.withLock { $0.append(message) }
        }

        try writer.startWriting(
            segmentsDir: fixture.segmentsDirectory,
            recordingID: fixture.recordingID
        )
        writer.rotateSegmentForTesting()

        let completionFailureArrived = await waitUntil {
            writeAttempts.withLock { $0 } >= 3
                && failureMessages.withLock { $0.count } == 1
        }
        #expect(completionFailureArrived)

        let manifestURL = fixture.segmentsDirectory.appendingPathComponent("segments.json")
        let previousManifestData = try Data(contentsOf: manifestURL)
        let previousInventory = try directoryInventory(at: fixture.segmentsDirectory)
        let previousManifest = try readManifest(at: fixture.segmentsDirectory)
        #expect(previousManifest.segments.map(\.filename) == [
            "segment-000.m4a",
            "segment-001.m4a",
        ])
        #expect(previousInventory == Set(
            previousManifest.segments.map(\.filename) + ["segments.json"]
        ))

        #expect(await writer.stopWriting().count == 2)

        #expect(writeAttempts.withLock { $0 } >= 4)
        #expect(failureMessages.withLock { $0.count } == 1)
        #expect(try Data(contentsOf: manifestURL) == previousManifestData)
        #expect(try directoryInventory(at: fixture.segmentsDirectory) == previousInventory)
    }
}

@Suite("SegmentedAudioFileWriter whole-manifest trust", .serialized)
struct SegmentedAudioFileWriterManifestTests {
    @Test func rejectsTraversalAbsoluteNestedMismatchedAndNegativeEntries() async throws {
        let outsideName = "outside-\(UUID().uuidString).m4a"
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: "/tmp/\(outsideName)")
            )
        }
        let attacks: [(index: Int, filename: String)] = [
            (0, "../../\(outsideName)"),
            (0, "/tmp/\(outsideName)"),
            (0, "nested/segment-000.m4a"),
            (0, "segment-001.m4a"),
            (-1, "segment--01.m4a"),
        ]

        for attack in attacks {
            let fixture = try SegmentManifestFixture.make()
            defer { fixture.remove() }
            try fixture.writeFile(named: attack.filename)
            try fixture.writeManifest(entries: [
                segmentEntry(index: attack.index, filename: attack.filename),
            ])

            let result = await validateForTaskOne(fixture)

            #expect(result.isTrustFailure, "entry must fail closed: \(attack.filename)")
        }
    }

    @Test func rejectsRecordingIDMismatch() async throws {
        let fixture = try SegmentManifestFixture.make()
        defer { fixture.remove() }
        try fixture.writeFile(named: segmentFilename(0))
        try fixture.writeManifest(
            recordingID: UUID(),
            entries: [segmentEntry(index: 0)]
        )

        #expect((await validateForTaskOne(fixture)).isTrustFailure)
    }

    @Test func rejectsDuplicateOutOfOrderAndGappedIndices() async throws {
        let invalidOrders = [
            [0, 0],
            [1, 0],
            [0, 2],
        ]

        for indices in invalidOrders {
            let fixture = try SegmentManifestFixture.make()
            defer { fixture.remove() }
            for index in Set(indices) {
                try fixture.writeFile(named: segmentFilename(index))
            }
            try fixture.writeManifest(entries: indices.map { segmentEntry(index: $0) })

            #expect(
                (await validateForTaskOne(fixture)).isTrustFailure,
                "manifest order must be contiguous: \(indices)"
            )
        }
    }

    @Test func rejectsMissingEmptyDirectorySymlinkAndFIFORequiredSegments() async throws {
        enum InvalidKind: CaseIterable {
            case missing
            case empty
            case directory
            case symlink
            case fifo
        }

        for kind in InvalidKind.allCases {
            let fixture = try SegmentManifestFixture.make()
            defer { fixture.remove() }
            try fixture.writeFile(named: segmentFilename(0))
            let invalidURL = fixture.segmentURL(segmentFilename(1))
            switch kind {
            case .missing:
                break
            case .empty:
                try Data().write(to: invalidURL)
            case .directory:
                try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: false)
            case .symlink:
                let outside = fixture.scratchRoot.appendingPathComponent("outside.m4a")
                try Data([0xAA]).write(to: outside)
                try FileManager.default.createSymbolicLink(at: invalidURL, withDestinationURL: outside)
            case .fifo:
                let result = invalidURL.path.withCString {
                    Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
                }
                try #require(result == 0)
            }
            try fixture.writeManifest(entries: [
                segmentEntry(index: 0),
                segmentEntry(index: 1),
            ])

            #expect(
                (await validateForTaskOne(fixture)).isTrustFailure,
                "required \(kind) segment must reject the whole manifest"
            )
        }
    }

    @Test func rejectsOversizedAndSymlinkedManifest() async throws {
        let oversized = try SegmentManifestFixture.make()
        defer { oversized.remove() }
        try oversized.writeFile(named: segmentFilename(0))
        try oversized.writeManifest(
            entries: [segmentEntry(index: 0)],
            trailingWhitespaceBytes: 300_000
        )
        #expect((await validateForTaskOne(oversized)).isTrustFailure)

        let linked = try SegmentManifestFixture.make()
        defer { linked.remove() }
        try linked.writeFile(named: segmentFilename(0))
        let outsideManifest = linked.scratchRoot.appendingPathComponent("outside-manifest.json")
        try linked.writeManifest(
            entries: [segmentEntry(index: 0)],
            at: outsideManifest
        )
        try FileManager.default.createSymbolicLink(
            at: linked.segmentsDirectory.appendingPathComponent("segments.json"),
            withDestinationURL: outsideManifest
        )
        #expect((await validateForTaskOne(linked)).isTrustFailure)
    }

    @Test func rejectsMissingMalformedDirectoryAndFIFOManifest() async throws {
        enum InvalidManifestKind: CaseIterable {
            case missing
            case malformed
            case directory
            case fifo
        }

        for kind in InvalidManifestKind.allCases {
            let fixture = try SegmentManifestFixture.make()
            defer { fixture.remove() }
            try fixture.writeFile(named: segmentFilename(0))
            let manifestURL = fixture.segmentURL("segments.json")
            switch kind {
            case .missing:
                break
            case .malformed:
                try Data("{not-json".utf8).write(to: manifestURL)
            case .directory:
                try FileManager.default.createDirectory(
                    at: manifestURL,
                    withIntermediateDirectories: false
                )
            case .fifo:
                let result = manifestURL.path.withCString {
                    Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
                }
                try #require(result == 0)
            }

            #expect(
                (await validateForTaskOne(fixture)).isTrustFailure,
                "invalid \(kind) manifest must fail closed"
            )
        }
    }

    @Test func rejectsHardlinkedSegmentAndManifest() async throws {
        let linkedSegment = try SegmentManifestFixture.make()
        defer { linkedSegment.remove() }
        let outsideSegment = linkedSegment.scratchRoot.appendingPathComponent("other-recording.m4a")
        try Data([0x11, 0x22]).write(to: outsideSegment)
        try FileManager.default.linkItem(
            at: outsideSegment,
            to: linkedSegment.segmentURL(segmentFilename(0))
        )
        try linkedSegment.writeManifest(entries: [segmentEntry(index: 0)])
        #expect((await validateForTaskOne(linkedSegment)).isTrustFailure)

        let linkedManifest = try SegmentManifestFixture.make()
        defer { linkedManifest.remove() }
        try linkedManifest.writeFile(named: segmentFilename(0))
        let outsideManifest = linkedManifest.scratchRoot
            .appendingPathComponent("other-recording-manifest.json")
        try linkedManifest.writeManifest(
            entries: [segmentEntry(index: 0)],
            at: outsideManifest
        )
        try FileManager.default.linkItem(
            at: outsideManifest,
            to: linkedManifest.segmentURL("segments.json")
        )
        #expect((await validateForTaskOne(linkedManifest)).isTrustFailure)
    }

    @Test func rejectsDirectoryOutsideAuthorityWrongLayoutWrongIDAndSymlink() async throws {
        let outside = try SegmentManifestFixture.make()
        defer { outside.remove() }
        try outside.writeValidManifest(segmentCount: 1)
        let differentAuthority = outside.scratchRoot
            .appendingPathComponent("different-authority", isDirectory: true)
        try FileManager.default.createDirectory(
            at: differentAuthority,
            withIntermediateDirectories: true
        )
        #expect(
            (await validateForTaskOne(outside, authorityRoot: differentAuthority)).isTrustFailure
        )

        let wrongLayoutID = UUID()
        let wrongLayout = try SegmentManifestFixture.make(
            relativeDirectory: ["recovery", wrongLayoutID.uuidString],
            recordingID: wrongLayoutID
        )
        defer { wrongLayout.remove() }
        try wrongLayout.writeValidManifest(segmentCount: 1)
        #expect((await validateForTaskOne(wrongLayout)).isTrustFailure)

        let requestedID = UUID()
        let wrongID = try SegmentManifestFixture.make(
            relativeDirectory: ["segments", UUID().uuidString],
            recordingID: requestedID
        )
        defer { wrongID.remove() }
        try wrongID.writeValidManifest(segmentCount: 1)
        #expect((await validateForTaskOne(wrongID)).isTrustFailure)

        let linkedScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-dir-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linkedScratch) }
        let linkedID = UUID()
        let linkedAuthority = linkedScratch.appendingPathComponent("authorized", isDirectory: true)
        let linkedPath = linkedAuthority
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(linkedID.uuidString, isDirectory: true)
        let realPath = linkedScratch.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: realPath, withIntermediateDirectories: true)
        let linkedFixture = SegmentManifestFixture(
            scratchRoot: linkedScratch,
            authorityRoot: linkedAuthority,
            recordingID: linkedID,
            segmentsDirectory: realPath
        )
        try linkedFixture.writeValidManifest(segmentCount: 1)
        try FileManager.default.createSymbolicLink(at: linkedPath, withDestinationURL: realPath)
        let requestedLinkedFixture = SegmentManifestFixture(
            scratchRoot: linkedScratch,
            authorityRoot: linkedAuthority,
            recordingID: linkedID,
            segmentsDirectory: linkedPath
        )
        #expect((await validateForTaskOne(requestedLinkedFixture)).isTrustFailure)
    }

    @Test func rejectsUnlistedFileNestedDirectoryAndSecondManifest() async throws {
        enum UnexpectedKind: CaseIterable {
            case file
            case directory
            case secondManifest
        }

        for kind in UnexpectedKind.allCases {
            let fixture = try SegmentManifestFixture.make()
            defer { fixture.remove() }
            try fixture.writeValidManifest(segmentCount: 1)
            switch kind {
            case .file:
                try Data([0x99]).write(to: fixture.segmentURL("unlisted.bin"))
            case .directory:
                try FileManager.default.createDirectory(
                    at: fixture.segmentURL("nested"),
                    withIntermediateDirectories: false
                )
            case .secondManifest:
                try Data("{}".utf8).write(to: fixture.segmentURL("segments-copy.json"))
            }

            #expect(
                (await validateForTaskOne(fixture)).isTrustFailure,
                "unexpected \(kind) must reject exact inventory"
            )
        }
    }

    @Test func detectsDirectoryIdentityReplacementBeforeMerge() async throws {
        let fixture = try SegmentManifestFixture.make()
        defer { fixture.remove() }
        try fixture.writeValidManifest(segmentCount: 1)
        let validation = await validateForTaskOne(fixture)
        guard case .trusted = validation else {
            Issue.record("valid fixture did not produce a trust token")
            return
        }
        let original = fixture.scratchRoot.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.segmentsDirectory, to: original)
        try FileManager.default.createDirectory(
            at: fixture.segmentsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: original.appendingPathComponent(segmentFilename(0)),
            to: fixture.segmentURL(segmentFilename(0))
        )
        try FileManager.default.copyItem(
            at: original.appendingPathComponent("segments.json"),
            to: fixture.segmentURL("segments.json")
        )

        #expect(!recheckForTaskOne(validation))
    }

    @Test func segmentSymlinkSwapBeforeMergeRunsNoDownstreamOperation() async throws {
        let fixture = try SegmentManifestFixture.make()
        defer { fixture.remove() }
        try fixture.writeValidManifest(segmentCount: 1)
        let segmentURL = fixture.segmentURL(segmentFilename(0))
        let outsideMarker = fixture.scratchRoot.appendingPathComponent("outside-marker.m4a")
        let markerBytes = Data([0xCA, 0xDE])
        try markerBytes.write(to: outsideMarker)
        let spy = TaskOneFinalizerSpy()
        let finalizer = RecordingAudioFinalizer(
            dependencies: RecordingAudioFinalizerDependencies(
                validate: { request in
                    let validated = await RecordingAudioFinalizer.validateSegments(request)
                    if case .trusted = validated {
                        try? FileManager.default.removeItem(at: segmentURL)
                        try? FileManager.default.createSymbolicLink(
                            at: segmentURL,
                            withDestinationURL: outsideMarker
                        )
                    }
                    return validated
                },
                recheckBeforeMerge: { validated in
                    validated.recheckForMerge()
                },
                mergeStage: { request, _ in
                    await spy.recordMerge()
                    return RecordingAudioPreparedArtifact(
                        outputURL: request.outputURL,
                        mergedDuration: 1
                    )
                },
                publish: { _, artifact in
                    await spy.recordPublish()
                    return artifact.outputURL.map(
                        RecordingAudioPublication.init(audioURL:)
                    )
                },
                storeCommit: { _ in
                    await spy.recordStore()
                    return .saved
                },
                cleanup: { _ in
                    await spy.recordCleanup()
                    return .cleaned
                },
                cleanupPublished: { _, _ in .cleaned },
                postProcess: { _, _ in await spy.recordPostProcess() },
                recordEvent: { _ in }
            )
        )

        _ = await finalizer.finalize(fixture.request())

        #expect(await spy.mergeCalls == 0)
        #expect(await spy.publishCalls == 0)
        #expect(await spy.storeCalls == 0)
        #expect(await spy.cleanupCalls == 0)
        #expect(await spy.postProcessCalls == 0)
        #expect(try Data(contentsOf: outsideMarker) == markerBytes)
        let symlinkDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: segmentURL.path
        )
        #expect(symlinkDestination == outsideMarker.path)
    }

    @Test func validationTrustFailureRunsNoDownstreamOperation() async throws {
        let fixture = try SegmentManifestFixture.make()
        defer { fixture.remove() }
        let escaped = "../../outside.m4a"
        let outsideBytes = Data([0xBA, 0xD0])
        try fixture.writeFile(named: escaped, data: outsideBytes)
        let outsideURL = fixture.segmentURL(escaped).standardizedFileURL
        try fixture.writeManifest(entries: [segmentEntry(index: 0, filename: escaped)])
        let spy = TaskOneFinalizerSpy()
        let finalizer = RecordingAudioFinalizer(
            dependencies: RecordingAudioFinalizerDependencies(
                validate: { request in
                    await RecordingAudioFinalizer.validateSegments(request)
                },
                recheckBeforeMerge: { validated in
                    validated.recheckForMerge()
                },
                mergeStage: { request, _ in
                    await spy.recordMerge()
                    return RecordingAudioPreparedArtifact(
                        outputURL: request.outputURL,
                        mergedDuration: 1
                    )
                },
                publish: { _, artifact in
                    await spy.recordPublish()
                    return artifact.outputURL.map(
                        RecordingAudioPublication.init(audioURL:)
                    )
                },
                storeCommit: { _ in
                    await spy.recordStore()
                    return .saved
                },
                cleanup: { _ in
                    await spy.recordCleanup()
                    return .cleaned
                },
                cleanupPublished: { _, _ in .cleaned },
                postProcess: { _, _ in await spy.recordPostProcess() },
                recordEvent: { _ in }
            )
        )

        _ = await finalizer.finalize(fixture.request())

        #expect(await spy.mergeCalls == 0)
        #expect(await spy.publishCalls == 0)
        #expect(await spy.storeCalls == 0)
        #expect(await spy.cleanupCalls == 0)
        #expect(await spy.postProcessCalls == 0)
        #expect(try Data(contentsOf: outsideURL) == outsideBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.request().outputURL!.path))
    }

    @Test func acceptsCompleteManifestUnderCurrentAndSeparatelySuppliedOldAuthority() async throws {
        let current = try SegmentManifestFixture.make()
        defer { current.remove() }
        try current.writeValidManifest()
        #expect(!(await validateForTaskOne(current)).isTrustFailure)

        let old = try SegmentManifestFixture.make()
        defer { old.remove() }
        try old.writeValidManifest()
        let activeRoot = old.scratchRoot.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        #expect((await validateForTaskOne(old, authorityRoot: activeRoot)).isTrustFailure)
        #expect(!(await validateForTaskOne(old, authorityRoot: old.authorityRoot)).isTrustFailure)
    }
}
