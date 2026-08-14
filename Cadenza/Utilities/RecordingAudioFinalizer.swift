import CryptoKit
import Darwin
import Foundation
import os

/// Finalization failures are only ever seen once — the recording is already
/// over and the user gets one alert. `NSLog` is not persisted at its default
/// level on macOS 26, so a Release-build failure left no evidence at all
/// (observed 2026-08-10: a 58-segment recording failed to merge and the log
/// held nothing past "started"). These go through `os.Logger` so `log show`
/// can still answer "which stage failed" after the fact.
private let finalizerLog = Logger(
    subsystem: "com.shuiandy.Cadenza",
    category: "RecordingAudioFinalizer"
)

enum RecordingAudioFinalizationOrigin: Sendable {
    case normalStop
    case crashRecovery
}

enum RecordingAudioFinalizationEvent: Sendable, Equatable {
    case validation
    case mergeStage
    case publish
    case storeCommit
    case cleanup
    case postProcess
}

enum RecordingAudioCommitResult: Sendable, Equatable {
    case saved
    case discarded
    case failed
}

enum RecordingAudioCleanupResult: Sendable, Equatable {
    case cleaned
    case alreadyClean
    case preserved(String)

    var warning: String? {
        guard case .preserved(let reason) = self else { return nil }
        return reason
    }
}

enum RecordingAudioPublishedCleanupMode: Sendable, Equatable {
    /// A failed Store transaction may remove only the link created by this
    /// finalization attempt. An idempotently reused destination is preserved.
    case rollbackFailedCommit
    /// Once model deletion is durable, the exact bound recording output is no
    /// longer owned by any row and should be removed even when it was reused.
    case discardAfterSavedDelete
}

struct RecordingAudioFinalizationRequest: Sendable {
    let origin: RecordingAudioFinalizationOrigin
    let recordingID: UUID
    let segmentsDirectory: URL?
    let suppliedSegmentURLs: [URL]
    let segmentStorageAuthority: SegmentStorageAuthority?
    let outputURL: URL?
    let fallbackDuration: TimeInterval
    let startDate: Date?
    let endDate: Date
    let meetingTitle: String?
    let mergeTimeoutSeconds: Int

    init(
        origin: RecordingAudioFinalizationOrigin,
        recordingID: UUID,
        segmentsDirectory: URL?,
        suppliedSegmentURLs: [URL],
        segmentStorageAuthority: SegmentStorageAuthority? = nil,
        outputURL: URL?,
        fallbackDuration: TimeInterval,
        startDate: Date? = nil,
        endDate: Date,
        meetingTitle: String?,
        mergeTimeoutSeconds: Int = 300
    ) {
        self.origin = origin
        self.recordingID = recordingID
        self.segmentsDirectory = segmentsDirectory
        self.suppliedSegmentURLs = suppliedSegmentURLs
        self.segmentStorageAuthority = segmentStorageAuthority
        self.outputURL = outputURL
        self.fallbackDuration = fallbackDuration
        self.startDate = startDate
        self.endDate = endDate
        self.meetingTitle = meetingTitle
        self.mergeTimeoutSeconds = mergeTimeoutSeconds
    }
}

struct RecordingAudioValidatedSegments: Sendable {
    fileprivate let trustedSegments: TrustedSegmentSet
    let estimatedDuration: TimeInterval?
    let endDate: Date?

    fileprivate init(
        trustedSegments: TrustedSegmentSet,
        estimatedDuration: TimeInterval? = nil,
        endDate: Date? = nil
    ) {
        self.trustedSegments = trustedSegments
        self.estimatedDuration = estimatedDuration
        self.endDate = endDate
    }

    fileprivate var segmentURLs: [URL] {
        trustedSegments.legacySegmentURLsForMerge()
    }

    fileprivate var segmentsDirectory: URL {
        trustedSegments.segmentsDirectory
    }

    fileprivate var storageAuthority: SegmentStorageAuthority {
        trustedSegments.storageAuthority
    }

    func recheckForMerge() -> Bool {
        SegmentedAudioFileWriter.recheckForMerge(trustedSegments)
    }

    func cleanupSources() -> RecordingAudioCleanupResult {
        SegmentedAudioFileWriter.cleanupTrustedSegments(trustedSegments)
    }
}

enum RecordingAudioValidation: Sendable {
    case trusted(RecordingAudioValidatedSegments)
    case trustFailure(String)
}

struct RecordingAudioPreparedArtifact: Sendable {
    let outputURL: URL?
    let mergedDuration: TimeInterval?
    let shouldCleanupSegments: Bool
    fileprivate let stagedArtifact: RecordingAudioStagedArtifact?

    init(
        outputURL: URL?,
        mergedDuration: TimeInterval?,
        shouldCleanupSegments: Bool = true,
        stagedArtifact: RecordingAudioStagedArtifact? = nil
    ) {
        self.outputURL = outputURL
        self.mergedDuration = mergedDuration
        self.shouldCleanupSegments = shouldCleanupSegments
        self.stagedArtifact = stagedArtifact
    }
}

struct RecordingAudioStagedArtifact: Sendable {
    let stagingDirectoryURL: URL
    let stagedOutputURL: URL
    let destinationURL: URL
    let mergedDuration: TimeInterval
    fileprivate let stagingDirectoryBasename: String
    fileprivate let stagingDirectoryIdentity: SegmentObjectIdentity
    fileprivate let inputDirectoryIdentity: SegmentObjectIdentity
    fileprivate let stagedOutputIdentity: SegmentObjectIdentity
    fileprivate let privateInputCopies: TrustedPrivateSegmentSet
    fileprivate let authority: SegmentStorageAuthority
    fileprivate let trustedSegments: TrustedSegmentSet
}

struct RecordingAudioPublication: Sendable {
    let audioURL: URL
    let createdByThisAttempt: Bool
    fileprivate let destinationBasename: String?
    fileprivate let destinationIdentity: SegmentObjectIdentity?
    fileprivate let authority: SegmentStorageAuthority?

    /// Dependency-injection seam for orchestration tests. Production
    /// publication is minted only by `RecordingAudioArtifactPipeline.publish`.
    init(audioURL: URL) {
        self.audioURL = audioURL
        createdByThisAttempt = false
        destinationBasename = nil
        destinationIdentity = nil
        authority = nil
    }

    fileprivate init(
        audioURL: URL,
        createdByThisAttempt: Bool,
        destinationBasename: String,
        destinationIdentity: SegmentObjectIdentity,
        authority: SegmentStorageAuthority
    ) {
        self.audioURL = audioURL
        self.createdByThisAttempt = createdByThisAttempt
        self.destinationBasename = destinationBasename
        self.destinationIdentity = destinationIdentity
        self.authority = authority
    }
}

enum RecordingAudioArtifactError: Error, LocalizedError, Sendable {
    case invalidAuthority
    case cannotCreatePrivateStage
    case privateStageChanged
    case invalidStagedAudio
    case destinationCollision
    case publicationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAuthority:
            return "The recording storage authority is no longer valid"
        case .cannotCreatePrivateStage:
            return "A private audio staging directory could not be created"
        case .privateStageChanged:
            return "The private audio staging directory changed unexpectedly"
        case .invalidStagedAudio:
            return "The staged recording is not complete decodable audio"
        case .destinationCollision:
            return "A different recording output already exists"
        case .publicationFailed(let code):
            return "Recording publication failed: \(String(cString: strerror(code)))"
        }
    }
}

enum RecordingAudioArtifactPipeline {
    typealias MergeOperation = @Sendable (
        _ segments: [URL],
        _ outputURL: URL,
        _ timeoutSeconds: Int
    ) async throws -> AudioSegmentMerger.MergeResult

    static func prepare(
        _ request: RecordingAudioFinalizationRequest,
        segments: RecordingAudioValidatedSegments,
        timeoutSeconds: Int? = nil,
        merge: MergeOperation? = nil
    ) async throws -> RecordingAudioStagedArtifact {
        let effectiveTimeout = timeoutSeconds ?? request.mergeTimeoutSeconds
        guard effectiveTimeout > 0 else {
            throw AudioSegmentMerger.MergeError.exportTimedOut(effectiveTimeout)
        }
        try Task.checkCancellation()

        let authority = segments.storageAuthority
        let rootDescriptor = try openAuthorizedRoot(authority)
        defer { _ = Darwin.close(rootDescriptor) }
        let deadline = ContinuousClock.now + .seconds(effectiveTimeout)

        let stageBasename = try createUniqueStage(
            rootDescriptor: rootDescriptor,
            recordingID: request.recordingID
        )
        let stageURL = authority.openedRootURL.appendingPathComponent(
            stageBasename,
            isDirectory: true
        )
        let stageDescriptor = Darwin.openat(
            rootDescriptor,
            stageBasename,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard stageDescriptor >= 0 else {
            throw RecordingAudioArtifactError.cannotCreatePrivateStage
        }
        defer { _ = Darwin.close(stageDescriptor) }

        var stageStatus = stat()
        guard Darwin.fstat(stageDescriptor, &stageStatus) == 0 else {
            throw RecordingAudioArtifactError.cannotCreatePrivateStage
        }
        let stageIdentity = SegmentObjectIdentity(stageStatus)
        guard isPrivateDirectory(stageStatus),
              Darwin.fchmod(stageDescriptor, mode_t(0o700)) == 0 else {
            removeDirectoryIfIdentityMatches(
                parentDescriptor: rootDescriptor,
                basename: stageBasename,
                identity: stageIdentity
            )
            throw RecordingAudioArtifactError.cannotCreatePrivateStage
        }

        guard Darwin.mkdirat(stageDescriptor, "inputs", mode_t(0o700)) == 0 else {
            cleanupIncompleteStage(
                rootDescriptor: rootDescriptor,
                stageDescriptor: stageDescriptor,
                stageBasename: stageBasename,
                stageIdentity: stageIdentity,
                inputDescriptor: nil,
                inputIdentity: nil,
                privateCopies: nil,
                outputDescriptor: nil,
                outputIdentity: nil
            )
            throw RecordingAudioArtifactError.cannotCreatePrivateStage
        }
        let inputDescriptor = Darwin.openat(
            stageDescriptor,
            "inputs",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard inputDescriptor >= 0 else {
            cleanupIncompleteStage(
                rootDescriptor: rootDescriptor,
                stageDescriptor: stageDescriptor,
                stageBasename: stageBasename,
                stageIdentity: stageIdentity,
                inputDescriptor: nil,
                inputIdentity: nil,
                privateCopies: nil,
                outputDescriptor: nil,
                outputIdentity: nil
            )
            throw RecordingAudioArtifactError.cannotCreatePrivateStage
        }
        defer { _ = Darwin.close(inputDescriptor) }

        var inputStatus = stat()
        guard Darwin.fstat(inputDescriptor, &inputStatus) == 0,
              isPrivateDirectory(inputStatus),
              Darwin.fchmod(inputDescriptor, mode_t(0o700)) == 0 else {
            cleanupIncompleteStage(
                rootDescriptor: rootDescriptor,
                stageDescriptor: stageDescriptor,
                stageBasename: stageBasename,
                stageIdentity: stageIdentity,
                inputDescriptor: inputDescriptor,
                inputIdentity: nil,
                privateCopies: nil,
                outputDescriptor: nil,
                outputIdentity: nil
            )
            throw RecordingAudioArtifactError.cannotCreatePrivateStage
        }
        let inputIdentity = SegmentObjectIdentity(inputStatus)
        let inputDirectoryURL = stageURL.appendingPathComponent("inputs", isDirectory: true)
        var privateCopies: TrustedPrivateSegmentSet?
        var incompleteOutputIdentity: SegmentObjectIdentity?

        do {
            let copiedSet = try SegmentedAudioFileWriter.copyVerifiedSegments(
                segments.trustedSegments,
                to: inputDescriptor,
                destinationDirectoryURL: inputDirectoryURL,
                deadline: deadline
            )
            privateCopies = copiedSet
            for index in 0..<copiedSet.count {
                guard stagePathMatches(
                    stageURL: stageURL,
                    descriptor: stageDescriptor,
                    identity: stageIdentity
                ), SegmentedAudioFileWriter.recheckPrivateCopy(
                    copiedSet,
                    at: index,
                    in: inputDescriptor
                ) else {
                    throw RecordingAudioArtifactError.privateStageChanged
                }
            }

            guard SegmentedAudioFileWriter.recheckPrivateCopies(
                copiedSet,
                in: inputDescriptor
            ), stagePathMatches(
                stageURL: stageURL,
                descriptor: stageDescriptor,
                identity: stageIdentity
            ) else {
                throw RecordingAudioArtifactError.privateStageChanged
            }

            let stagedOutputURL = stageURL.appendingPathComponent("merged.m4a")
            let usesProductionMerger = merge == nil
            let mergeOperation: MergeOperation = merge ?? { inputURLs, outputURL, seconds in
                try await AudioSegmentMerger.mergeValidatedPrivateCopies(
                    segments: inputURLs,
                    outputURL: outputURL,
                    timeoutSeconds: seconds
                )
            }
            let mergeInputs = copiedSet.decodingURLs()
            let mergeTimeout = try remainingSeconds(until: deadline)
            let mergeResult = try await runBeforeDeadline(
                deadline: deadline,
                timeoutSeconds: effectiveTimeout
            ) {
                try await mergeOperation(
                    mergeInputs,
                    stagedOutputURL,
                    mergeTimeout
                )
            }
            try Task.checkCancellation()
            guard SegmentedAudioFileWriter.recheckPrivateCopies(
                copiedSet,
                in: inputDescriptor
            ), stagePathMatches(
                stageURL: stageURL,
                descriptor: stageDescriptor,
                identity: stageIdentity
            ) else {
                throw RecordingAudioArtifactError.privateStageChanged
            }

            let outputDescriptor = Darwin.openat(
                stageDescriptor,
                "merged.m4a",
                O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard outputDescriptor >= 0 else {
                throw RecordingAudioArtifactError.privateStageChanged
            }
            defer { _ = Darwin.close(outputDescriptor) }
            var outputStatus = stat()
            guard Darwin.fstat(outputDescriptor, &outputStatus) == 0,
                  isOwnedSingleLinkRegularFile(outputStatus),
                  outputStatus.st_size > 0,
                  Darwin.fchmod(outputDescriptor, mode_t(0o600)) == 0,
                  Darwin.fsync(outputDescriptor) == 0 else {
                throw RecordingAudioArtifactError.invalidStagedAudio
            }
            let outputIdentity = SegmentObjectIdentity(outputStatus)
            incompleteOutputIdentity = outputIdentity
            guard stagedOutputPathMatches(
                stagedOutputURL: stagedOutputURL,
                stageDescriptor: stageDescriptor,
                identity: outputIdentity
            ) else {
                throw RecordingAudioArtifactError.privateStageChanged
            }

            guard mergeResult.trimmedCount >= 0,
                  mergeResult.trimmedCount < copiedSet.count,
                  mergeResult.mergedDuration.isFinite,
                  mergeResult.mergedDuration > 0 else {
                throw RecordingAudioArtifactError.invalidStagedAudio
            }

            let validatedOutputDuration: TimeInterval
            if usesProductionMerger, mergeResult.completedFullValidation {
                let reopenedOutputDigest = try streamingDigest(
                    descriptor: outputDescriptor,
                    deadline: deadline,
                    timeoutSeconds: effectiveTimeout
                )
                guard mergeResult.validatedOutputMatches(
                    outputStatus,
                    digest: reopenedOutputDigest
                ) else {
                    throw RecordingAudioArtifactError.privateStageChanged
                }
                // The production merger already decoded every required input
                // and the complete staged output through EOF. Repeating that
                // work here adds two linear passes to every stop operation.
                validatedOutputDuration = mergeResult.mergedDuration
            } else {
                // Preserve the strict trust boundary for injected/custom merge
                // operations: independently validate all inputs and the output
                // before accepting their unverified result.
                var stagedInputDurations: [TimeInterval] = []
                stagedInputDurations.reserveCapacity(copiedSet.count)
                for inputURL in copiedSet.decodingURLs() {
                    let inputTimeout = try remainingSeconds(until: deadline)
                    stagedInputDurations.append(
                        try await runBeforeDeadline(
                            deadline: deadline,
                            timeoutSeconds: effectiveTimeout
                        ) {
                            try await AudioSegmentMerger.validateDecodableAudio(
                                at: inputURL,
                                timeoutSeconds: inputTimeout
                            )
                        }
                    )
                }
                let outputTimeout = try remainingSeconds(until: deadline)
                validatedOutputDuration = try await runBeforeDeadline(
                    deadline: deadline,
                    timeoutSeconds: effectiveTimeout
                ) {
                    try await AudioSegmentMerger.validateDecodableAudio(
                        at: stagedOutputURL,
                        timeoutSeconds: outputTimeout
                    )
                }
                let expectedOutputDuration = stagedInputDurations
                    .dropLast(mergeResult.trimmedCount)
                    .reduce(0, +)
                let boundaries = max(0, stagedInputDurations.count - 1)
                guard AudioSegmentMerger.durationsMatch(
                    outputDuration: validatedOutputDuration,
                    expectedDuration: expectedOutputDuration,
                    boundaries: boundaries
                ), AudioSegmentMerger.durationsMatch(
                    outputDuration: validatedOutputDuration,
                    expectedDuration: mergeResult.mergedDuration,
                    boundaries: boundaries
                ) else {
                    throw RecordingAudioArtifactError.invalidStagedAudio
                }
            }

            var finalStageStatus = stat()
            var finalInputStatus = stat()
            var finalOutputStatus = stat()
            guard Darwin.fstat(stageDescriptor, &finalStageStatus) == 0,
                  stageIdentity.matches(finalStageStatus, includingSize: false),
                  Darwin.fstat(inputDescriptor, &finalInputStatus) == 0,
                  inputIdentity.matches(finalInputStatus, includingSize: false),
                  Darwin.fstat(outputDescriptor, &finalOutputStatus) == 0,
                  outputIdentity.matches(finalOutputStatus, includingSize: true),
                  stagePathMatches(
                    stageURL: stageURL,
                    descriptor: stageDescriptor,
                    identity: stageIdentity
                  ), stagedOutputPathMatches(
                    stagedOutputURL: stagedOutputURL,
                    stageDescriptor: stageDescriptor,
                    identity: outputIdentity
                  ), SegmentedAudioFileWriter.recheckPrivateCopies(
                    copiedSet,
                    in: inputDescriptor
                  ) else {
                throw RecordingAudioArtifactError.privateStageChanged
            }
            try Task.checkCancellation()
            _ = try remainingSeconds(until: deadline)

            return RecordingAudioStagedArtifact(
                stagingDirectoryURL: stageURL,
                stagedOutputURL: stagedOutputURL,
                destinationURL: authority.openedRootURL.appendingPathComponent(
                    "recording-\(request.recordingID.uuidString).m4a"
                ),
                mergedDuration: validatedOutputDuration,
                stagingDirectoryBasename: stageBasename,
                stagingDirectoryIdentity: stageIdentity,
                inputDirectoryIdentity: inputIdentity,
                stagedOutputIdentity: outputIdentity,
                privateInputCopies: copiedSet,
                authority: authority,
                trustedSegments: segments.trustedSegments
            )
        } catch {
            // A merge that threw before returning never authorized a pathname
            // occupant for destructive cleanup. The production merger removes
            // only its own fd-bound output; unknown injected/replaced residue is
            // quarantined with the stage instead of being adopted after failure.
            let capturedOutput = incompleteOutputIdentity.flatMap { _ in
                openOwnedRegularFile(
                    parentDescriptor: stageDescriptor,
                    basename: "merged.m4a"
                )
            }
            var cleanupOutputIdentity: SegmentObjectIdentity?
            if let capturedOutput, let incompleteOutputIdentity {
                if incompleteOutputIdentity.matches(
                    capturedOutput.status,
                    includingSize: true
                ) {
                    cleanupOutputIdentity = incompleteOutputIdentity
                }
            }
            cleanupIncompleteStage(
                rootDescriptor: rootDescriptor,
                stageDescriptor: stageDescriptor,
                stageBasename: stageBasename,
                stageIdentity: stageIdentity,
                inputDescriptor: inputDescriptor,
                inputIdentity: inputIdentity,
                privateCopies: privateCopies,
                outputDescriptor: capturedOutput?.descriptor,
                outputIdentity: cleanupOutputIdentity
            )
            if let capturedOutput {
                _ = Darwin.close(capturedOutput.descriptor)
            }
            throw error
        }
    }

    static func publish(
        _ artifact: RecordingAudioStagedArtifact
    ) throws -> RecordingAudioPublication {
        try Task.checkCancellation()
        let rootDescriptor = try openAuthorizedRoot(artifact.authority)
        defer { _ = Darwin.close(rootDescriptor) }
        var createdDestinationLink = false
        defer {
            cleanupStage(
                artifact,
                expectedOutputLinkCount: createdDestinationLink ? 2 : 1
            )
        }

        let stageDescriptor = Darwin.openat(
            rootDescriptor,
            artifact.stagingDirectoryBasename,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard stageDescriptor >= 0 else {
            throw RecordingAudioArtifactError.privateStageChanged
        }
        defer { _ = Darwin.close(stageDescriptor) }
        var stageStatus = stat()
        guard Darwin.fstat(stageDescriptor, &stageStatus) == 0,
              artifact.stagingDirectoryIdentity.matches(
                stageStatus,
                includingSize: false
              ) else {
            throw RecordingAudioArtifactError.privateStageChanged
        }

        let stagedDescriptor = Darwin.openat(
            stageDescriptor,
            "merged.m4a",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard stagedDescriptor >= 0 else {
            throw RecordingAudioArtifactError.privateStageChanged
        }
        defer { _ = Darwin.close(stagedDescriptor) }
        var stagedStatus = stat()
        guard Darwin.fstat(stagedDescriptor, &stagedStatus) == 0,
              isOwnedSingleLinkRegularFile(stagedStatus),
              artifact.stagedOutputIdentity.matches(stagedStatus, includingSize: true) else {
            throw RecordingAudioArtifactError.privateStageChanged
        }
        try Task.checkCancellation()

        let destinationBasename = artifact.destinationURL.lastPathComponent
        if Darwin.linkat(
            stageDescriptor,
            "merged.m4a",
            rootDescriptor,
            destinationBasename,
            0
        ) == 0 {
            createdDestinationLink = true
            let verified = verifyPublishedDestination(
                rootDescriptor: rootDescriptor,
                basename: destinationBasename,
                expectedIdentity: artifact.stagedOutputIdentity,
                expectedLinkCount: 2
            )
            let synced = verified && Darwin.fsync(rootDescriptor) == 0
            guard synced else {
                let failureCode = errno == 0 ? EIO : errno
                let rolledBack = rollbackPublishedLink(
                    rootDescriptor: rootDescriptor,
                    basename: destinationBasename,
                    expectedIdentity: artifact.stagedOutputIdentity
                )
                createdDestinationLink = !rolledBack
                throw RecordingAudioArtifactError.publicationFailed(failureCode)
            }
            do {
                try Task.checkCancellation()
            } catch {
                let rolledBack = rollbackPublishedLink(
                    rootDescriptor: rootDescriptor,
                    basename: destinationBasename,
                    expectedIdentity: artifact.stagedOutputIdentity
                )
                createdDestinationLink = !rolledBack
                throw error
            }
            return RecordingAudioPublication(
                audioURL: artifact.destinationURL,
                createdByThisAttempt: true,
                destinationBasename: destinationBasename,
                destinationIdentity: artifact.stagedOutputIdentity,
                authority: artifact.authority
            )
        }

        let linkError = errno
        guard linkError == EEXIST else {
            throw RecordingAudioArtifactError.publicationFailed(linkError)
        }
        let existingDescriptor = Darwin.openat(
            rootDescriptor,
            destinationBasename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard existingDescriptor >= 0 else {
            throw RecordingAudioArtifactError.destinationCollision
        }
        defer { _ = Darwin.close(existingDescriptor) }
        var existingStatus = stat()
        guard Darwin.fstat(existingDescriptor, &existingStatus) == 0,
              isOwnedSingleLinkRegularFile(existingStatus),
              existingStatus.st_size > 0,
              existingStatus.st_size == stagedStatus.st_size else {
            throw RecordingAudioArtifactError.destinationCollision
        }
        let existingIdentity = SegmentObjectIdentity(existingStatus)
        try Task.checkCancellation()
        let stagedDigest = try streamingDigest(descriptor: stagedDescriptor)
        try Task.checkCancellation()
        let existingDigest = try streamingDigest(descriptor: existingDescriptor)
        guard stagedDigest == existingDigest else {
            throw RecordingAudioArtifactError.destinationCollision
        }
        var finalExistingStatus = stat()
        guard Darwin.fstat(existingDescriptor, &finalExistingStatus) == 0,
              existingIdentity.matches(finalExistingStatus, includingSize: true),
              verifyPublishedDestination(
                rootDescriptor: rootDescriptor,
                basename: destinationBasename,
                expectedIdentity: existingIdentity,
                expectedLinkCount: 1
              ) else {
            throw RecordingAudioArtifactError.destinationCollision
        }
        try Task.checkCancellation()
        return RecordingAudioPublication(
            audioURL: artifact.destinationURL,
            createdByThisAttempt: false,
            destinationBasename: destinationBasename,
            destinationIdentity: existingIdentity,
            authority: artifact.authority
        )
    }

    static func cleanupPublished(
        _ publication: RecordingAudioPublication,
        mode: RecordingAudioPublishedCleanupMode
    ) -> RecordingAudioCleanupResult {
        if mode == .rollbackFailedCommit,
           !publication.createdByThisAttempt {
            return .alreadyClean
        }
        guard let authority = publication.authority,
              let basename = publication.destinationBasename,
              let identity = publication.destinationIdentity else {
            return .preserved("Published output has no identity-bound cleanup authority")
        }
        let rootDescriptor: Int32
        do {
            rootDescriptor = try openAuthorizedRoot(authority)
        } catch {
            return .preserved("Published output authority changed before cleanup")
        }
        defer { _ = Darwin.close(rootDescriptor) }

        let descriptor = Darwin.openat(
            rootDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        if descriptor < 0, errno == ENOENT {
            return .alreadyClean
        }
        guard descriptor >= 0 else {
            return .preserved("Published output cannot be reopened without following links")
        }
        defer { _ = Darwin.close(descriptor) }
        var openedStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              isRegularFile(openedStatus),
              openedStatus.st_uid == Darwin.geteuid(),
              openedStatus.st_nlink > 0,
              identity.matches(openedStatus, includingSize: true),
              Darwin.fstatat(
                rootDescriptor,
                basename,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              isRegularFile(pathStatus),
              pathStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_nlink == openedStatus.st_nlink,
              identity.matches(pathStatus, includingSize: true) else {
            return .preserved("Published output identity changed before cleanup")
        }
        guard Darwin.unlinkat(rootDescriptor, basename, 0) == 0,
              Darwin.fsync(rootDescriptor) == 0 else {
            return .preserved("Published output could not be durably removed")
        }
        return .cleaned
    }

    private static func openAuthorizedRoot(
        _ authority: SegmentStorageAuthority
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            authority.openedRootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw RecordingAudioArtifactError.invalidAuthority
        }
        var rootStatus = stat()
        guard Darwin.fstat(descriptor, &rootStatus) == 0,
              isDirectory(rootStatus),
              authority.rootIdentity.matches(rootStatus, includingSize: false) else {
            _ = Darwin.close(descriptor)
            throw RecordingAudioArtifactError.invalidAuthority
        }
        return descriptor
    }

    private static func createUniqueStage(
        rootDescriptor: Int32,
        recordingID: UUID
    ) throws -> String {
        for _ in 0..<16 {
            let basename = ".cadenza-stage-\(recordingID.uuidString)-\(UUID().uuidString)"
            if Darwin.mkdirat(rootDescriptor, basename, mode_t(0o700)) == 0 {
                return basename
            }
            guard errno == EEXIST else {
                throw RecordingAudioArtifactError.cannotCreatePrivateStage
            }
        }
        throw RecordingAudioArtifactError.cannotCreatePrivateStage
    }

    private static func remainingSeconds(
        until deadline: ContinuousClock.Instant
    ) throws -> Int {
        try Task.checkCancellation()
        let now = ContinuousClock.now
        guard now < deadline else {
            throw AudioSegmentMerger.MergeError.exportTimedOut(0)
        }
        let components = now.duration(to: deadline).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        return max(1, Int(ceil(seconds)))
    }

    private static func runBeforeDeadline<Value: Sendable>(
        deadline: ContinuousClock.Instant,
        timeoutSeconds: Int,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let now = ContinuousClock.now
        guard now < deadline else {
            throw AudioSegmentMerger.MergeError.exportTimedOut(timeoutSeconds)
        }
        do {
            return try await HardAsyncDeadline.run(
                for: now.duration(to: deadline),
                operation: operation
            )
        } catch is HardAsyncDeadlineExceeded {
            throw AudioSegmentMerger.MergeError.exportTimedOut(timeoutSeconds)
        }
    }

    private static func streamingDigest(
        descriptor: Int32,
        deadline: ContinuousClock.Instant? = nil,
        timeoutSeconds: Int = 0
    ) throws -> SHA256.Digest {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw RecordingAudioArtifactError.privateStageChanged
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline {
                throw AudioSegmentMerger.MergeError.exportTimedOut(timeoutSeconds)
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw RecordingAudioArtifactError.privateStageChanged
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize()
    }

    private static func verifyPublishedDestination(
        rootDescriptor: Int32,
        basename: String,
        expectedIdentity: SegmentObjectIdentity,
        expectedLinkCount: nlink_t
    ) -> Bool {
        var destinationStatus = stat()
        return Darwin.fstatat(
            rootDescriptor,
            basename,
            &destinationStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0
            && isRegularFile(destinationStatus)
            && destinationStatus.st_uid == Darwin.geteuid()
            && destinationStatus.st_nlink == expectedLinkCount
            && expectedIdentity.matches(destinationStatus, includingSize: true)
    }

    private static func cleanupStage(
        _ artifact: RecordingAudioStagedArtifact,
        expectedOutputLinkCount: nlink_t
    ) {
        guard let rootDescriptor = try? openAuthorizedRoot(artifact.authority) else { return }
        defer { _ = Darwin.close(rootDescriptor) }
        let stageDescriptor = Darwin.openat(
            rootDescriptor,
            artifact.stagingDirectoryBasename,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard stageDescriptor >= 0 else { return }
        defer { _ = Darwin.close(stageDescriptor) }
        var stageStatus = stat()
        guard Darwin.fstat(stageDescriptor, &stageStatus) == 0,
              artifact.stagingDirectoryIdentity.matches(
                stageStatus,
                includingSize: false
              ) else { return }

        let inputDescriptor = Darwin.openat(
            stageDescriptor,
            "inputs",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if inputDescriptor >= 0 {
            var inputStatus = stat()
            if Darwin.fstat(inputDescriptor, &inputStatus) == 0,
               artifact.inputDirectoryIdentity.matches(inputStatus, includingSize: false) {
                SegmentedAudioFileWriter.removeVerifiedPrivateCopies(
                    artifact.privateInputCopies,
                    from: inputDescriptor
                )
            }
            // Keep the opened directory alive through the identity-checked
            // rmdir so its inode cannot be recycled into a replacement.
            removeDirectoryIfIdentityMatches(
                parentDescriptor: stageDescriptor,
                basename: "inputs",
                identity: artifact.inputDirectoryIdentity
            )
            _ = Darwin.close(inputDescriptor)
        }

        removeRegularFileIfIdentityMatches(
            parentDescriptor: stageDescriptor,
            basename: "merged.m4a",
            identity: artifact.stagedOutputIdentity,
            expectedLinkCount: expectedOutputLinkCount
        )
        var pathStageStatus = stat()
        if Darwin.fstatat(
            rootDescriptor,
            artifact.stagingDirectoryBasename,
            &pathStageStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
           artifact.stagingDirectoryIdentity.matches(
            pathStageStatus,
            includingSize: false
           ) {
            _ = Darwin.unlinkat(
                rootDescriptor,
                artifact.stagingDirectoryBasename,
                AT_REMOVEDIR
            )
        }
    }

    private static func cleanupIncompleteStage(
        rootDescriptor: Int32,
        stageDescriptor: Int32,
        stageBasename: String,
        stageIdentity: SegmentObjectIdentity,
        inputDescriptor: Int32?,
        inputIdentity: SegmentObjectIdentity?,
        privateCopies: TrustedPrivateSegmentSet?,
        outputDescriptor: Int32?,
        outputIdentity: SegmentObjectIdentity?
    ) {
        if let inputDescriptor, let inputIdentity {
            var openedInputStatus = stat()
            if Darwin.fstat(inputDescriptor, &openedInputStatus) == 0,
               inputIdentity.matches(openedInputStatus, includingSize: false),
               let privateCopies {
                SegmentedAudioFileWriter.removeVerifiedPrivateCopies(
                    privateCopies,
                    from: inputDescriptor
                )
            }
            removeDirectoryIfIdentityMatches(
                parentDescriptor: stageDescriptor,
                basename: "inputs",
                identity: inputIdentity
            )
        }
        if let outputIdentity {
            removeRegularFileIfIdentityMatches(
                parentDescriptor: stageDescriptor,
                basename: "merged.m4a",
                identity: outputIdentity,
                holdingDescriptor: outputDescriptor
            )
        }
        removeDirectoryIfIdentityMatches(
            parentDescriptor: rootDescriptor,
            basename: stageBasename,
            identity: stageIdentity
        )
    }

    private static func stagePathMatches(
        stageURL: URL,
        descriptor: Int32,
        identity: SegmentObjectIdentity
    ) -> Bool {
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              identity.matches(descriptorStatus, includingSize: false) else {
            return false
        }
        let pathDescriptor = Darwin.open(
            stageURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard pathDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(pathDescriptor) }
        var pathStatus = stat()
        return Darwin.fstat(pathDescriptor, &pathStatus) == 0
            && identity.matches(pathStatus, includingSize: false)
    }

    private static func stagedOutputPathMatches(
        stagedOutputURL: URL,
        stageDescriptor: Int32,
        identity: SegmentObjectIdentity
    ) -> Bool {
        let relativeDescriptor = Darwin.openat(
            stageDescriptor,
            "merged.m4a",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard relativeDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(relativeDescriptor) }
        var relativeStatus = stat()
        guard Darwin.fstat(relativeDescriptor, &relativeStatus) == 0,
              identity.matches(relativeStatus, includingSize: true) else {
            return false
        }

        let pathDescriptor = Darwin.open(
            stagedOutputURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard pathDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(pathDescriptor) }
        var pathStatus = stat()
        return Darwin.fstat(pathDescriptor, &pathStatus) == 0
            && identity.matches(pathStatus, includingSize: true)
    }

    private static func rollbackPublishedLink(
        rootDescriptor: Int32,
        basename: String,
        expectedIdentity: SegmentObjectIdentity
    ) -> Bool {
        var status = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            basename,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              isRegularFile(status),
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 2,
              expectedIdentity.matches(status, includingSize: true) else {
            return false
        }
        guard Darwin.unlinkat(rootDescriptor, basename, 0) == 0 else {
            return false
        }
        _ = Darwin.fsync(rootDescriptor)
        return true
    }

    private static func removeRegularFileIfIdentityMatches(
        parentDescriptor: Int32,
        basename: String,
        identity: SegmentObjectIdentity,
        holdingDescriptor: Int32? = nil,
        expectedLinkCount: nlink_t = 1
    ) {
        let descriptor = holdingDescriptor ?? Darwin.openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return }
        let ownsDescriptor = holdingDescriptor == nil
        defer {
            if ownsDescriptor { _ = Darwin.close(descriptor) }
        }
        var openedStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              isRegularFile(openedStatus),
              openedStatus.st_uid == Darwin.geteuid(),
              openedStatus.st_nlink == expectedLinkCount,
              identity.matches(openedStatus, includingSize: true),
              Darwin.fstatat(
                parentDescriptor,
                basename,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              pathStatus.st_nlink == expectedLinkCount,
              identity.matches(pathStatus, includingSize: true) else {
            return
        }
        _ = Darwin.unlinkat(parentDescriptor, basename, 0)
    }

    private static func openOwnedRegularFile(
        parentDescriptor: Int32,
        basename: String
    ) -> (descriptor: Int32, status: stat)? {
        let descriptor = Darwin.openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              isOwnedSingleLinkRegularFile(status) else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return (descriptor, status)
    }

    private static func removeDirectoryIfIdentityMatches(
        parentDescriptor: Int32,
        basename: String,
        identity: SegmentObjectIdentity
    ) {
        var status = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            basename,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              isDirectory(status),
              identity.matches(status, includingSize: false) else {
            return
        }
        _ = Darwin.unlinkat(parentDescriptor, basename, AT_REMOVEDIR)
    }

    private static func isDirectory(_ fileStatus: stat) -> Bool {
        fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isRegularFile(_ fileStatus: stat) -> Bool {
        fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func isPrivateDirectory(_ fileStatus: stat) -> Bool {
        isDirectory(fileStatus)
            && fileStatus.st_uid == Darwin.geteuid()
            && fileStatus.st_mode & mode_t(0o077) == 0
    }

    private static func isOwnedSingleLinkRegularFile(_ fileStatus: stat) -> Bool {
        isRegularFile(fileStatus)
            && fileStatus.st_uid == Darwin.geteuid()
            && fileStatus.st_nlink == 1
    }
}

struct RecordingAudioStoreCommitRequest: Sendable {
    let finalization: RecordingAudioFinalizationRequest
    let audioURL: URL?
    let duration: TimeInterval
    let endDate: Date
    let didPrepareAudio: Bool
}

struct RecordingAudioFinalizationOutcome: Sendable {
    let commitResult: RecordingAudioCommitResult
    let audioURL: URL?
    let duration: TimeInterval
    let didPrepareAudio: Bool
    let trustFailureReason: String?
    let cleanupWarning: String?
}

struct RecordingAudioFinalizerDependencies: Sendable {
    let validate: @Sendable (
        _ request: RecordingAudioFinalizationRequest
    ) async -> RecordingAudioValidation
    let recheckBeforeMerge: @Sendable (
        _ segments: RecordingAudioValidatedSegments
    ) async -> Bool
    let mergeStage: @Sendable (
        _ request: RecordingAudioFinalizationRequest,
        _ segments: RecordingAudioValidatedSegments
    ) async -> RecordingAudioPreparedArtifact?
    let publish: @Sendable (
        _ request: RecordingAudioFinalizationRequest,
        _ artifact: RecordingAudioPreparedArtifact
    ) async -> RecordingAudioPublication?
    let storeCommit: @Sendable (
        _ request: RecordingAudioStoreCommitRequest
    ) async -> RecordingAudioCommitResult
    let cleanup: @Sendable (
        _ segments: RecordingAudioValidatedSegments
    ) async -> RecordingAudioCleanupResult
    let cleanupPublished: @Sendable (
        _ publication: RecordingAudioPublication,
        _ mode: RecordingAudioPublishedCleanupMode
    ) async -> RecordingAudioCleanupResult
    let postProcess: @Sendable (
        _ request: RecordingAudioFinalizationRequest,
        _ audioURL: URL
    ) async -> Void
    let recordEvent: @Sendable (
        _ event: RecordingAudioFinalizationEvent
    ) async -> Void
}

/// Shared durable orchestration for normal-stop and crash-recovery finalization.
/// A saved commit cleans exact sources before post-processing; discard and
/// failure outcomes take their own identity-bound cleanup paths.
struct RecordingAudioFinalizer: Sendable {
    let dependencies: RecordingAudioFinalizerDependencies

    static func validateSegments(
        _ request: RecordingAudioFinalizationRequest
    ) async -> RecordingAudioValidation {
        guard let segmentsDirectory = request.segmentsDirectory,
              let authority = request.segmentStorageAuthority else {
            return .trustFailure("No explicit segment storage authority")
        }
        switch SegmentedAudioFileWriter.validateManifest(
            recordingID: request.recordingID,
            segmentsDirectory: segmentsDirectory,
            authority: authority
        ) {
        case .trustFailure(let reason):
            return .trustFailure(reason)
        case .trusted(let trustedSegments):
            // Task 1 deliberately does not decode source audio. Task 2 validates
            // decodability after copying verified inputs into private staging.
            let estimatedDuration = TimeInterval(trustedSegments.count)
                * SegmentedAudioFileWriter.segmentDuration
            // Only a persisted segment completion timestamp is stronger than
            // the caller's captured recovery fallback. Segment count is an
            // estimate and must not manufacture a new wall-clock stop time.
            let endDate = trustedSegments.manifest.segments
                .last(where: { $0.completedAt != nil })?.completedAt
            return .trusted(
                RecordingAudioValidatedSegments(
                    trustedSegments: trustedSegments,
                    estimatedDuration: estimatedDuration,
                    endDate: endDate
                )
            )
        }
    }

    func finalize(
        _ request: RecordingAudioFinalizationRequest
    ) async -> RecordingAudioFinalizationOutcome {
        await dependencies.recordEvent(.validation)
        let validated: RecordingAudioValidatedSegments
        switch await dependencies.validate(request) {
        case .trusted(let trusted):
            validated = trusted
        case .trustFailure(let reason):
            finalizerLog.error(
                "validation rejected \(request.recordingID.uuidString, privacy: .public): \(reason, privacy: .public)"
            )
            return trustFailureOutcome(request, reason: reason)
        }

        guard await dependencies.recheckBeforeMerge(validated) else {
            finalizerLog.error(
                "recheck rejected \(request.recordingID.uuidString, privacy: .public): segment identity changed before merge"
            )
            return trustFailureOutcome(
                request,
                reason: "Segment identity changed before merge"
            )
        }

        await dependencies.recordEvent(.mergeStage)
        guard let artifact = await dependencies.mergeStage(request, validated) else {
            finalizerLog.error(
                "merge stage produced no artifact for \(request.recordingID.uuidString, privacy: .public)"
            )
            return failedPreparationOutcome(
                duration: validated.estimatedDuration ?? request.fallbackDuration
            )
        }

        await dependencies.recordEvent(.publish)
        guard let publication = await dependencies.publish(request, artifact) else {
            return failedPreparationOutcome(
                duration: artifact.mergedDuration.flatMap { $0 > 0 ? $0 : nil }
                    ?? validated.estimatedDuration
                    ?? request.fallbackDuration
            )
        }
        let duration = artifact.mergedDuration.flatMap { $0 > 0 ? $0 : nil }
            ?? validated.estimatedDuration
            ?? request.fallbackDuration
        let durableEndDate: Date
        switch request.origin {
        case .normalStop:
            // A normal stop owns a wall-clock timestamp captured by the
            // recording engine. Never replace it with a duration estimate.
            durableEndDate = request.endDate
        case .crashRecovery:
            // Recovery has no trustworthy live stop callback. Prefer the
            // manifest-derived completion timestamp when validation supplied
            // one, and retain the request value only as a compatibility
            // fallback for older manifests.
            durableEndDate = validated.endDate ?? request.endDate
        }

        await dependencies.recordEvent(.storeCommit)
        let commitResult = await dependencies.storeCommit(
            RecordingAudioStoreCommitRequest(
                finalization: request,
                audioURL: publication.audioURL,
                duration: duration,
                endDate: durableEndDate,
                didPrepareAudio: true
            )
        )

        switch commitResult {
        case .saved:
            var cleanupWarning: String?
            if artifact.shouldCleanupSegments {
                await dependencies.recordEvent(.cleanup)
                cleanupWarning = await dependencies.cleanup(validated).warning
            }
            await dependencies.recordEvent(.postProcess)
            await dependencies.postProcess(request, publication.audioURL)
            return RecordingAudioFinalizationOutcome(
                commitResult: .saved,
                audioURL: publication.audioURL,
                duration: duration,
                didPrepareAudio: true,
                trustFailureReason: nil,
                cleanupWarning: cleanupWarning
            )

        case .discarded:
            await dependencies.recordEvent(.cleanup)
            var cleanupWarnings: [String] = []
            if let warning = await dependencies.cleanupPublished(
                publication,
                .discardAfterSavedDelete
            ).warning {
                cleanupWarnings.append(warning)
            }
            if artifact.shouldCleanupSegments,
               let warning = await dependencies.cleanup(validated).warning {
                cleanupWarnings.append(warning)
            }
            return RecordingAudioFinalizationOutcome(
                commitResult: .discarded,
                audioURL: nil,
                duration: duration,
                didPrepareAudio: false,
                trustFailureReason: nil,
                cleanupWarning: cleanupWarnings.isEmpty
                    ? nil
                    : cleanupWarnings.joined(separator: "; ")
            )

        case .failed:
            let cleanupWarning = await dependencies.cleanupPublished(
                publication,
                .rollbackFailedCommit
            ).warning
            return RecordingAudioFinalizationOutcome(
                commitResult: .failed,
                audioURL: nil,
                duration: duration,
                didPrepareAudio: false,
                trustFailureReason: nil,
                cleanupWarning: cleanupWarning
            )
        }
    }

    private func trustFailureOutcome(
        _ request: RecordingAudioFinalizationRequest,
        reason: String
    ) -> RecordingAudioFinalizationOutcome {
        RecordingAudioFinalizationOutcome(
            commitResult: .failed,
            audioURL: nil,
            duration: request.fallbackDuration,
            didPrepareAudio: false,
            trustFailureReason: reason,
            cleanupWarning: nil
        )
    }

    private func failedPreparationOutcome(
        duration: TimeInterval
    ) -> RecordingAudioFinalizationOutcome {
        RecordingAudioFinalizationOutcome(
            commitResult: .failed,
            audioURL: nil,
            duration: duration,
            didPrepareAudio: false,
            trustFailureReason: nil,
            cleanupWarning: nil
        )
    }
}

extension RecordingAudioFinalizerDependencies {
    static func legacy(
        storeCommit: @escaping @Sendable (
            RecordingAudioStoreCommitRequest
        ) async -> RecordingAudioCommitResult,
        postProcess: @escaping @Sendable (
            RecordingAudioFinalizationRequest,
            URL
        ) async -> Void,
        recordEvent: @escaping @Sendable (
            RecordingAudioFinalizationEvent
        ) async -> Void = { _ in }
    ) -> Self {
        Self(
            validate: { request in
                await RecordingAudioFinalizer.validateSegments(request)
            },
            recheckBeforeMerge: { validated in
                validated.recheckForMerge()
            },
            mergeStage: { request, validated in
                do {
                    let stagedArtifact = try await RecordingAudioArtifactPipeline.prepare(
                        request,
                        segments: validated
                    )
                    return RecordingAudioPreparedArtifact(
                        outputURL: stagedArtifact.stagedOutputURL,
                        mergedDuration: stagedArtifact.mergedDuration,
                        shouldCleanupSegments: true,
                        stagedArtifact: stagedArtifact
                    )
                } catch {
                    // The error text embeds file URLs — the user's home, their
                    // chosen recordings directory, recording UUIDs — and these
                    // now persist (that was the point). Only the shape is public.
                    finalizerLog.error(
                        "merge failed: \(String(describing: type(of: error)), privacy: .public) — \(error.localizedDescription, privacy: .private)"
                    )
                    return nil
                }
            },
            publish: { _, artifact in
                guard let stagedArtifact = artifact.stagedArtifact else {
                    return artifact.outputURL.map(RecordingAudioPublication.init(audioURL:))
                }
                do {
                    return try RecordingAudioArtifactPipeline.publish(stagedArtifact)
                } catch {
                    finalizerLog.error(
                        "publish failed: \(String(describing: type(of: error)), privacy: .public) — \(error.localizedDescription, privacy: .private)"
                    )
                    return nil
                }
            },
            storeCommit: storeCommit,
            cleanup: { validated in
                validated.cleanupSources()
            },
            cleanupPublished: { publication, mode in
                RecordingAudioArtifactPipeline.cleanupPublished(
                    publication,
                    mode: mode
                )
            },
            postProcess: postProcess,
            recordEvent: recordEvent
        )
    }
}
