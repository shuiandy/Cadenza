import Foundation
import Darwin
import Testing
@testable import Cadenza

private actor RecordingAudioFinalizerEventSpy {
    private(set) var events: [RecordingAudioFinalizationEvent] = []

    func record(_ event: RecordingAudioFinalizationEvent) {
        events.append(event)
    }
}

private actor StagingMergeProbe {
    private var started = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !started, ContinuousClock.now < deadline {
            await Task.yield()
        }
        return started
    }
}

private actor HardLinkCreationProbe {
    private(set) var didCreate = false
    private(set) var errorDescription: String?

    func create(from source: URL, to destination: URL) {
        do {
            try FileManager.default.linkItem(at: source, to: destination)
            didCreate = true
        } catch {
            errorDescription = error.localizedDescription
        }
    }
}

private actor StoreCommitEndDateProbe {
    private(set) var endDate: Date?

    func record(_ endDate: Date) {
        self.endDate = endDate
    }
}

private enum RecordingAudioFinalizerTestError: Error {
    case validationFailed
    case injectedWriterFailure
}

@Suite("Recording audio finalizer transaction seam", .serialized)
struct RecordingAudioFinalizerTests {
    private struct AudioFixture {
        let storageRoot: URL
        let segmentsDirectory: URL
        let recordingID: UUID
        let sourceURLs: [URL]
        let sourceBytes: [Data]
        let request: RecordingAudioFinalizationRequest
        let validated: RecordingAudioValidatedSegments
    }

    @Test func taskOneRecoveryValidationRejectsFilteredSubset() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-zero-validation-\(UUID().uuidString)", isDirectory: true)
        let recordingID = UUID()
        let segmentsDirectory = storageRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let validURL = segmentsDirectory.appendingPathComponent("segment-000.m4a")
        try Data([0x01]).write(to: validURL)
        let manifest = SegmentedAudioFileWriter.SegmentManifest(
            recordingID: recordingID.uuidString,
            segments: [
                SegmentedAudioFileWriter.SegmentEntry(
                    index: 0,
                    filename: validURL.lastPathComponent,
                    startedAt: Date(),
                    completedAt: Date()
                ),
                SegmentedAudioFileWriter.SegmentEntry(
                    index: 1,
                    filename: "segment-001.m4a",
                    startedAt: Date(),
                    completedAt: Date()
                ),
            ],
            isComplete: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: segmentsDirectory.appendingPathComponent("segments.json")
        )
        let request = RecordingAudioFinalizationRequest(
            origin: .crashRecovery,
            recordingID: recordingID,
            segmentsDirectory: segmentsDirectory,
            suppliedSegmentURLs: [],
            segmentStorageAuthority: SegmentStorageAuthority.authorize(root: storageRoot),
            outputURL: storageRoot.appendingPathComponent("output.m4a"),
            fallbackDuration: 30,
            endDate: Date(),
            meetingTitle: nil
        )

        let validation = await RecordingAudioFinalizer.validateSegments(request)

        guard case .trustFailure = validation else {
            Issue.record("Expected whole-set trust failure for a missing manifest entry")
            return
        }
    }

    @Test func normalStopCommitsBeforeCleanupAndPostProcess() async throws {
        let spy = RecordingAudioFinalizerEventSpy()
        let fixture = try makeRequest(origin: .normalStop)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let finalizer = makeFinalizer(spy: spy)

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .saved)
        #expect(await spy.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
            .cleanup,
            .postProcess,
        ])
    }

    @Test func crashRecoveryCommitsBeforeCleanupAndPostProcess() async throws {
        let spy = RecordingAudioFinalizerEventSpy()
        let fixture = try makeRequest(origin: .crashRecovery)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let finalizer = makeFinalizer(spy: spy)

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .saved)
        #expect(await spy.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
            .cleanup,
            .postProcess,
        ])
    }

    @Test func failedStoreCommitNeverCleansSourcesOrStartsPostProcess() async throws {
        let spy = RecordingAudioFinalizerEventSpy()
        let fixture = try makeRequest(origin: .normalStop)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let finalizer = makeFinalizer(spy: spy, commitResult: .failed)

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .failed)
        #expect(await spy.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
        ])
    }

    @Test func discardedCommitCleansAfterDurableDeleteWithoutPostProcess() async throws {
        let spy = RecordingAudioFinalizerEventSpy()
        let fixture = try makeRequest(origin: .normalStop)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let finalizer = makeFinalizer(spy: spy, commitResult: .discarded)

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .discarded)
        #expect(await spy.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
            .cleanup,
        ])
    }

    @Test func preparationFailureDoesNotMutateStoreOrCleanOrPostProcess() async throws {
        let spy = RecordingAudioFinalizerEventSpy()
        let fixture = try makeRequest(origin: .crashRecovery)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let finalizer = makeFinalizer(
            spy: spy,
            mergeStage: { _, _ in nil }
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .failed)
        #expect(await spy.events == [.validation, .mergeStage])
    }

    @Test func productionStageUsesVerifiedPrivateCopiesAndUUIDDestination() async throws {
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-final-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let ignoredOutput = externalRoot.appendingPathComponent("persisted-final.m4a")
        let externalMarker = Data("outside-marker".utf8)
        try externalMarker.write(to: ignoredOutput)
        let fixture = try await makeAudioFixture(outputURL: ignoredOutput, segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let artifact = try await RecordingAudioArtifactPipeline.prepare(
            fixture.request,
            segments: fixture.validated
        )

        var stageStatus = stat()
        #expect(Darwin.lstat(artifact.stagingDirectoryURL.path, &stageStatus) == 0)
        #expect(stageStatus.st_mode & mode_t(0o777) == mode_t(0o700))
        var outputStatus = stat()
        #expect(Darwin.lstat(artifact.stagedOutputURL.path, &outputStatus) == 0)
        #expect(outputStatus.st_mode & mode_t(0o777) == mode_t(0o600))
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)

        let publishedURL = try RecordingAudioArtifactPipeline.publish(artifact).audioURL
        let expectedURL = fixture.storageRoot.appendingPathComponent(
            "recording-\(fixture.recordingID.uuidString).m4a"
        )
        #expect(publishedURL.standardizedFileURL == expectedURL.standardizedFileURL)
        #expect(try Data(contentsOf: ignoredOutput) == externalMarker)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
        let duration = try await AudioSegmentMerger.validateDecodableAudio(at: publishedURL)
        #expect(duration.isFinite && duration > 0)
        #expect(stagingEntries(in: fixture.storageRoot).isEmpty)
    }

    @Test func corruptInputNeverChangesPreexistingFinalMarker() async throws {
        let fixture = try await makeAudioFixture(corruptIndex: 0)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let destination = publishedURL(for: fixture)
        let marker = Data("preexisting-final-marker".utf8)
        try marker.write(to: destination)

        await #expect(throws: (any Error).self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated
            )
        }

        #expect(try Data(contentsOf: destination) == marker)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
        #expect(stagingEntries(in: fixture.storageRoot).isEmpty)
    }

    @Test func timeoutAndWriterFailureLeaveNoStageOrPublishedSuccess() async throws {
        let fixture = try await makeAudioFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        await #expect(throws: (any Error).self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated,
                timeoutSeconds: 0
            )
        }
        #expect(stagingEntries(in: fixture.storageRoot).isEmpty)

        await #expect(throws: RecordingAudioFinalizerTestError.self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated,
                merge: { _, outputURL, _ in
                    try Data("partial-writer-output".utf8).write(to: outputURL)
                    throw RecordingAudioFinalizerTestError.injectedWriterFailure
                }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        // The injected writer never returned an identity-bound artifact, so its
        // path residue is quarantined instead of adopted for deletion.
        #expect(stagingEntries(in: fixture.storageRoot).count == 1)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func cancellationRemovesOnlyPrivateStageAndPreservesSources() async throws {
        let fixture = try await makeAudioFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let probe = StagingMergeProbe()
        let task = Task {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated,
                merge: { _, outputURL, _ in
                    try Data("partial-writer-output".utf8).write(to: outputURL)
                    await probe.markStarted()
                    try await Task.sleep(for: .seconds(30))
                    throw RecordingAudioFinalizerTestError.injectedWriterFailure
                }
            )
        }
        let mergeStarted = await probe.waitUntilStarted()
        #expect(mergeStarted)
        if !mergeStarted {
            _ = try await task.value
            return
        }
        task.cancel()

        await #expect(throws: (any Error).self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(stagingEntries(in: fixture.storageRoot).count == 1)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func positiveDeadlineBoundsMergeThatIgnoresItsTimeoutArgument() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let startedAt = ContinuousClock.now

        await #expect(throws: (any Error).self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated,
                timeoutSeconds: 1,
                merge: { _, _, _ in
                    try await Task.sleep(for: .seconds(3))
                    throw RecordingAudioFinalizerTestError.injectedWriterFailure
                }
            )
        }

        #expect(ContinuousClock.now - startedAt < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(stagingEntries(in: fixture.storageRoot).isEmpty)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func stagedInputReplacementAfterValidationFailsClosed() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-input-\(UUID().uuidString).m4a")
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 24_000, amplitude: 0.8)],
            to: replacement
        )
        defer { try? FileManager.default.removeItem(at: replacement) }

        await #expect(throws: (any Error).self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated,
                merge: { inputURLs, outputURL, timeoutSeconds in
                    try FileManager.default.removeItem(at: inputURLs[0])
                    try FileManager.default.copyItem(at: replacement, to: inputURLs[0])
                    return try await AudioSegmentMerger.merge(
                        segments: inputURLs,
                        outputURL: outputURL,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        // The identity-mismatched replacement is quarantined in the private
        // stage rather than being treated as an authorized destructive target.
        #expect(stagingEntries(in: fixture.storageRoot).count == 1)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func validDecodablePrefixCannotMasqueradeAsCompleteOutput() async throws {
        let fixture = try await makeAudioFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        await #expect(throws: (any Error).self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated,
                merge: { inputURLs, outputURL, _ in
                    try FileManager.default.copyItem(at: inputURLs[0], to: outputURL)
                    let prefixDuration = try await AudioSegmentMerger.validateDecodableAudio(
                        at: outputURL
                    )
                    return AudioSegmentMerger.MergeResult(
                        mergedDuration: prefixDuration,
                        trimmedCount: 0,
                        skippedCount: 0
                    )
                }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(stagingEntries(in: fixture.storageRoot).isEmpty)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func injectedMergerCannotReuseProductionProofForOnlyAPrefix() async throws {
        let fixture = try await makeAudioFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        await #expect(throws: (any Error).self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated,
                merge: { inputURLs, outputURL, timeoutSeconds in
                    try await AudioSegmentMerger.merge(
                        segments: [inputURLs[0]],
                        outputURL: outputURL,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(stagingEntries(in: fixture.storageRoot).isEmpty)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func publishCollisionFailsClosedUnlessStreamingDigestMatches() async throws {
        let differentFixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: differentFixture.storageRoot) }
        let differentArtifact = try await RecordingAudioArtifactPipeline.prepare(
            differentFixture.request,
            segments: differentFixture.validated
        )
        let differentDestination = publishedURL(for: differentFixture)
        let marker = Data("different-existing-recording".utf8)
        try marker.write(to: differentDestination)

        #expect(throws: (any Error).self) {
            try RecordingAudioArtifactPipeline.publish(differentArtifact)
        }
        #expect(try Data(contentsOf: differentDestination) == marker)
        #expect(stagingEntries(in: differentFixture.storageRoot).isEmpty)

        let identicalFixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: identicalFixture.storageRoot) }
        let identicalArtifact = try await RecordingAudioArtifactPipeline.prepare(
            identicalFixture.request,
            segments: identicalFixture.validated
        )
        let identicalBytes = try Data(contentsOf: identicalArtifact.stagedOutputURL)
        let identicalDestination = publishedURL(for: identicalFixture)
        try identicalBytes.write(to: identicalDestination)

        let reusedURL = try RecordingAudioArtifactPipeline.publish(identicalArtifact).audioURL

        #expect(reusedURL.standardizedFileURL == identicalDestination.standardizedFileURL)
        #expect(try Data(contentsOf: identicalDestination) == identicalBytes)
        #expect(stagingEntries(in: identicalFixture.storageRoot).isEmpty)
    }

    @Test func symlinkCollisionAndSegmentReplacementNeverFollowOutsideTargets() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-audio-marker-\(UUID().uuidString)")
        let outsideMarker = Data("outside-audio-marker".utf8)
        try outsideMarker.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.removeItem(at: fixture.sourceURLs[0])
        try FileManager.default.createSymbolicLink(at: fixture.sourceURLs[0], withDestinationURL: outside)
        await #expect(throws: (any Error).self) {
            try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated
            )
        }
        #expect(try Data(contentsOf: outside) == outsideMarker)
        #expect(stagingEntries(in: fixture.storageRoot).isEmpty)

        let collisionFixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: collisionFixture.storageRoot) }
        let artifact = try await RecordingAudioArtifactPipeline.prepare(
            collisionFixture.request,
            segments: collisionFixture.validated
        )
        try FileManager.default.createSymbolicLink(
            at: publishedURL(for: collisionFixture),
            withDestinationURL: outside
        )
        #expect(throws: (any Error).self) {
            try RecordingAudioArtifactPipeline.publish(artifact)
        }
        #expect(try Data(contentsOf: outside) == outsideMarker)
        #expect(stagingEntries(in: collisionFixture.storageRoot).isEmpty)
    }

    @Test func replacedStagingPathCannotPublishOrTouchReplacement() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let artifact = try await RecordingAudioArtifactPipeline.prepare(
            fixture.request,
            segments: fixture.validated
        )
        let displacedStage = fixture.storageRoot.appendingPathComponent("displaced-stage")
        try FileManager.default.moveItem(
            at: artifact.stagingDirectoryURL,
            to: displacedStage
        )
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let outsideMarkerURL = outsideDirectory.appendingPathComponent("marker")
        let marker = Data("replacement-stage-marker".utf8)
        try marker.write(to: outsideMarkerURL)
        try FileManager.default.createSymbolicLink(
            at: artifact.stagingDirectoryURL,
            withDestinationURL: outsideDirectory
        )

        #expect(throws: (any Error).self) {
            try RecordingAudioArtifactPipeline.publish(artifact)
        }

        #expect(try Data(contentsOf: outsideMarkerURL) == marker)
        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(FileManager.default.fileExists(atPath: displacedStage.path))
    }

    @Test func persistedOutsideSymlinkAndOtherRecordingPathsAreNeverDestructiveTargets() async throws {
        let sharedOutside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ignored-persisted-target-\(UUID().uuidString)")
        let outsideMarker = Data("ignored-outside".utf8)
        try outsideMarker.write(to: sharedOutside)
        defer { try? FileManager.default.removeItem(at: sharedOutside) }

        for kind in 0..<3 {
            let seed = try await makeAudioFixture()
            defer { try? FileManager.default.removeItem(at: seed.storageRoot) }
            let otherRecording = seed.storageRoot.appendingPathComponent("recording-other.m4a")
            let symlink = seed.storageRoot.appendingPathComponent("legacy-link.m4a")
            let insideMarker = Data("other-recording".utf8)
            try insideMarker.write(to: otherRecording)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sharedOutside)
            let suppliedPath = [sharedOutside, symlink, otherRecording][kind]
            let fixture = try await makeAudioFixture(
                storageRoot: seed.storageRoot,
                recordingID: seed.recordingID,
                outputURL: suppliedPath,
                reuseExistingSegments: true
            )

            let artifact = try await RecordingAudioArtifactPipeline.prepare(
                fixture.request,
                segments: fixture.validated
            )
            let published = try RecordingAudioArtifactPipeline.publish(artifact).audioURL

            #expect(published.standardizedFileURL == publishedURL(for: fixture).standardizedFileURL)
            #expect(try Data(contentsOf: sharedOutside) == outsideMarker)
            #expect(try Data(contentsOf: otherRecording) == insideMarker)
        }
    }

    @Test func laterStoreFailureLeavesPersistedMarkerAndSourcesUntouched() async throws {
        let outsideMarkerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-failure-marker-\(UUID().uuidString)")
        let marker = Data("persisted-old-final".utf8)
        try marker.write(to: outsideMarkerURL)
        defer { try? FileManager.default.removeItem(at: outsideMarkerURL) }
        let fixture = try await makeAudioFixture(outputURL: outsideMarkerURL)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let events = RecordingAudioFinalizerEventSpy()
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in .failed },
                postProcess: { _, _ in },
                recordEvent: { event in await events.record(event) }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .failed)
        #expect(outcome.audioURL == nil)
        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(try Data(contentsOf: outsideMarkerURL) == marker)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
        #expect(FileManager.default.fileExists(atPath: fixture.segmentsDirectory.path))
        #expect(await events.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
        ])
    }

    @Test func savedProductionFinalizationCleansExactSourcesAfterCommit() async throws {
        let fixture = try await makeAudioFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let events = RecordingAudioFinalizerEventSpy()
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in .saved },
                postProcess: { _, _ in },
                recordEvent: { event in await events.record(event) }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .saved)
        #expect(FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.segmentsDirectory.path))
        #expect(await events.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
            .cleanup,
            .postProcess,
        ])
    }

    @Test func discardedProductionFinalizationCleansPublishedAndSourcesAfterCommit() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let events = RecordingAudioFinalizerEventSpy()
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in .discarded },
                postProcess: { _, _ in },
                recordEvent: { event in await events.record(event) }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .discarded)
        #expect(!FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.segmentsDirectory.path))
        #expect(await events.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
            .cleanup,
        ])
    }

    @Test func savedCleanupPreservesReplacedSourceAndRecoveryInventory() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let replacement = Data("replacement-segment".utf8)
        let sourceURL = try #require(fixture.sourceURLs.first)
        let manifestURL = fixture.segmentsDirectory.appendingPathComponent("segments.json")
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in
                    try? FileManager.default.removeItem(at: sourceURL)
                    try? replacement.write(to: sourceURL)
                    return .saved
                },
                postProcess: { _, _ in }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .saved)
        #expect(outcome.cleanupWarning != nil)
        #expect(try Data(contentsOf: sourceURL) == replacement)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: publishedURL(for: fixture).path))
    }

    @Test func savedCleanupDeletesOnlyTrustedFilesAndPreservesUnexpectedArtifact() async throws {
        let fixture = try await makeAudioFixture(segmentCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let markerURL = fixture.segmentsDirectory.appendingPathComponent("unexpected-marker")
        let marker = Data("preserve-me".utf8)
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in
                    try? marker.write(to: markerURL)
                    return .saved
                },
                postProcess: { _, _ in }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .saved)
        #expect(outcome.cleanupWarning != nil)
        #expect(try Data(contentsOf: markerURL) == marker)
        #expect(fixture.sourceURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(!FileManager.default.fileExists(
            atPath: fixture.segmentsDirectory.appendingPathComponent("segments.json").path
        ))
    }

    @Test func savedCleanupNeverTouchesReplacementSegmentsDirectory() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let displacedDirectory = fixture.storageRoot.appendingPathComponent(
            "displaced-segments",
            isDirectory: true
        )
        let replacementMarkerURL = fixture.segmentsDirectory.appendingPathComponent("marker")
        let marker = Data("replacement-directory".utf8)
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in
                    try? FileManager.default.moveItem(
                        at: fixture.segmentsDirectory,
                        to: displacedDirectory
                    )
                    try? FileManager.default.createDirectory(
                        at: fixture.segmentsDirectory,
                        withIntermediateDirectories: true
                    )
                    try? marker.write(to: replacementMarkerURL)
                    return .saved
                },
                postProcess: { _, _ in }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .saved)
        #expect(outcome.cleanupWarning != nil)
        #expect(try Data(contentsOf: replacementMarkerURL) == marker)
        #expect(FileManager.default.fileExists(
            atPath: displacedDirectory.appendingPathComponent("segments.json").path
        ))
    }

    @Test func failedCommitRollbackPreservesReplacementPublishedOutput() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let destination = publishedURL(for: fixture)
        let replacement = Data("replacement-published-output".utf8)
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in
                    try? FileManager.default.removeItem(at: destination)
                    try? replacement.write(to: destination)
                    return .failed
                },
                postProcess: { _, _ in }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .failed)
        #expect(outcome.audioURL == nil)
        #expect(outcome.cleanupWarning != nil)
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func failedCommitPreservesIdempotentlyReusedPublishedOutput() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let seedArtifact = try await RecordingAudioArtifactPipeline.prepare(
            fixture.request,
            segments: fixture.validated
        )
        let seededPublication = try RecordingAudioArtifactPipeline.publish(seedArtifact)
        let seededBytes = try Data(contentsOf: seededPublication.audioURL)
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in .failed },
                postProcess: { _, _ in }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .failed)
        #expect(outcome.cleanupWarning == nil)
        #expect(try Data(contentsOf: seededPublication.audioURL) == seededBytes)
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func failedCommitRollsBackCreatedDestinationWhenExactInodeHasAnotherLink() async throws {
        let fixture = try await makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let destination = publishedURL(for: fixture)
        let extraLink = fixture.storageRoot.appendingPathComponent("extra-owned-link.m4a")
        let linkProbe = HardLinkCreationProbe()
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { _ in
                    await linkProbe.create(from: destination, to: extraLink)
                    return .failed
                },
                postProcess: { _, _ in }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .failed)
        #expect(await linkProbe.didCreate)
        #expect(await linkProbe.errorDescription == nil)
        #expect(outcome.cleanupWarning == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: extraLink.path))
        #expect(try fixture.sourceURLs.map { try Data(contentsOf: $0) } == fixture.sourceBytes)
    }

    @Test func recoveryWithoutManifestCompletionUsesRequestEndDateFallback() async throws {
        let fixture = try await makeAudioFixture(
            segmentCount: 2,
            includeCompletionTimestamps: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let probe = StoreCommitEndDateProbe()
        let finalizer = RecordingAudioFinalizer(
            dependencies: .legacy(
                storeCommit: { request in
                    await probe.record(request.endDate)
                    return .failed
                },
                postProcess: { _, _ in }
            )
        )

        let outcome = await finalizer.finalize(fixture.request)

        #expect(outcome.commitResult == .failed)
        #expect(await probe.endDate == fixture.request.endDate)
    }

    private func makeRequest(
        origin: RecordingAudioFinalizationOrigin
    ) throws -> (request: RecordingAudioFinalizationRequest, storageRoot: URL) {
        let recordingID = UUID()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalizer-transaction-\(UUID().uuidString)", isDirectory: true)
        let segmentsDirectory = storageRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(
            to: segmentsDirectory.appendingPathComponent("segment-000.m4a")
        )
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let manifest = SegmentedAudioFileWriter.SegmentManifest(
            recordingID: recordingID.uuidString,
            segments: [
                SegmentedAudioFileWriter.SegmentEntry(
                    index: 0,
                    filename: "segment-000.m4a",
                    startedAt: now,
                    completedAt: now.addingTimeInterval(30)
                ),
            ],
            isComplete: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: segmentsDirectory.appendingPathComponent("segments.json")
        )
        let authority = SegmentStorageAuthority.authorize(root: storageRoot)
        return (
            RecordingAudioFinalizationRequest(
            origin: origin,
            recordingID: recordingID,
            segmentsDirectory: segmentsDirectory,
            suppliedSegmentURLs: [segmentsDirectory.appendingPathComponent("segment-000.m4a")],
            segmentStorageAuthority: authority,
            outputURL: storageRoot.appendingPathComponent("recording-\(recordingID).m4a"),
            fallbackDuration: 60,
            endDate: now,
            meetingTitle: "Transaction seam"
            ),
            storageRoot
        )
    }

    private func makeAudioFixture(
        storageRoot suppliedRoot: URL? = nil,
        recordingID suppliedRecordingID: UUID? = nil,
        outputURL: URL? = nil,
        segmentCount: Int = 1,
        corruptIndex: Int? = nil,
        includeCompletionTimestamps: Bool = true,
        reuseExistingSegments: Bool = false
    ) async throws -> AudioFixture {
        let recordingID = suppliedRecordingID ?? UUID()
        let storageRoot = suppliedRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-stage-fixture-\(UUID().uuidString)", isDirectory: true)
        let segmentsDirectory = storageRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        if !reuseExistingSegments {
            try FileManager.default.createDirectory(
                at: segmentsDirectory,
                withIntermediateDirectories: true
            )
        }

        var sourceURLs: [URL] = []
        if reuseExistingSegments {
            let names = try FileManager.default.contentsOfDirectory(atPath: segmentsDirectory.path)
                .filter { $0.hasPrefix("segment-") && $0.hasSuffix(".m4a") }
                .sorted()
            sourceURLs = names.map { segmentsDirectory.appendingPathComponent($0) }
        } else {
            for index in 0..<segmentCount {
                let segmentURL = segmentsDirectory.appendingPathComponent(
                    String(format: "segment-%03d.m4a", index)
                )
                if corruptIndex == index {
                    try Data([0x00, 0x01, 0x02, 0x03]).write(to: segmentURL)
                } else {
                    try await AudioTestFixtures.writeM4A(
                        tracks: [AudioTestFixtures.sine(count: 16_000, amplitude: 0.1)],
                        to: segmentURL
                    )
                }
                sourceURLs.append(segmentURL)
            }
            let now = Date(timeIntervalSinceReferenceDate: 1_000)
            let manifest = SegmentedAudioFileWriter.SegmentManifest(
                recordingID: recordingID.uuidString,
                segments: sourceURLs.enumerated().map { index, url in
                    SegmentedAudioFileWriter.SegmentEntry(
                        index: index,
                        filename: url.lastPathComponent,
                        startedAt: now.addingTimeInterval(TimeInterval(index * 30)),
                        completedAt: includeCompletionTimestamps
                            ? now.addingTimeInterval(TimeInterval((index + 1) * 30))
                            : nil
                    )
                },
                isComplete: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: segmentsDirectory.appendingPathComponent("segments.json")
            )
        }

        guard let authority = SegmentStorageAuthority.authorize(root: storageRoot) else {
            throw RecordingAudioFinalizerTestError.validationFailed
        }
        let request = RecordingAudioFinalizationRequest(
            origin: .crashRecovery,
            recordingID: recordingID,
            segmentsDirectory: segmentsDirectory,
            suppliedSegmentURLs: sourceURLs,
            segmentStorageAuthority: authority,
            outputURL: outputURL,
            fallbackDuration: TimeInterval(max(1, sourceURLs.count) * 30),
            startDate: Date(timeIntervalSinceReferenceDate: 1_000),
            endDate: Date(timeIntervalSinceReferenceDate: 1_030),
            meetingTitle: "Stage fixture"
        )
        let validation = await RecordingAudioFinalizer.validateSegments(request)
        guard case .trusted(let validated) = validation else {
            throw RecordingAudioFinalizerTestError.validationFailed
        }
        return AudioFixture(
            storageRoot: storageRoot,
            segmentsDirectory: segmentsDirectory,
            recordingID: recordingID,
            sourceURLs: sourceURLs,
            sourceBytes: try sourceURLs.map { try Data(contentsOf: $0) },
            request: request,
            validated: validated
        )
    }

    private func publishedURL(for fixture: AudioFixture) -> URL {
        fixture.storageRoot.appendingPathComponent(
            "recording-\(fixture.recordingID.uuidString).m4a"
        )
    }

    private func stagingEntries(in storageRoot: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.lastPathComponent.hasPrefix(".cadenza-stage-") }
    }

    private func makeFinalizer(
        spy: RecordingAudioFinalizerEventSpy,
        commitResult: RecordingAudioCommitResult = .saved,
        mergeStage: @escaping @Sendable (
            RecordingAudioFinalizationRequest,
            RecordingAudioValidatedSegments
        ) async -> RecordingAudioPreparedArtifact? = { request, _ in
            RecordingAudioPreparedArtifact(
                outputURL: request.outputURL,
                mergedDuration: 58
            )
        }
    ) -> RecordingAudioFinalizer {
        RecordingAudioFinalizer(
            dependencies: RecordingAudioFinalizerDependencies(
                validate: { request in
                    await RecordingAudioFinalizer.validateSegments(request)
                },
                recheckBeforeMerge: { validated in
                    validated.recheckForMerge()
                },
                mergeStage: mergeStage,
                publish: { _, artifact in
                    artifact.outputURL.map(RecordingAudioPublication.init(audioURL:))
                },
                storeCommit: { _ in commitResult },
                cleanup: { _ in .cleaned },
                cleanupPublished: { _, _ in .cleaned },
                postProcess: { _, _ in },
                recordEvent: { event in await spy.record(event) }
            )
        )
    }
}
