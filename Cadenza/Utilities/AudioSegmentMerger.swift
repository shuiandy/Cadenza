import Darwin
import AVFoundation
import CoreMedia
import CryptoKit

/// Merges multiple audio segment files into a single .m4a file.
enum AudioSegmentMerger {

    /// Result of a successful merge.
    struct MergeResult: Sendable {
        /// Positive duration validated from the complete staged output.
        let mergedDuration: TimeInterval
        /// Trailing fully-silent segments dropped before merging.
        let trimmedCount: Int
        /// Kept for call-site compatibility. Complete merges never skip input.
        let skippedCount: Int

        /// True only for results created after this merger has decoded every
        /// required input through EOF and then decoded the complete output.
        /// Injected test mergers use the module-visible initializer and
        /// remain unverified, so the finalizer independently validates them.
        fileprivate let validatedOutputIdentity: SegmentObjectIdentity?
        fileprivate let validatedOutputDigest: SHA256.Digest?

        init(
            mergedDuration: TimeInterval,
            trimmedCount: Int,
            skippedCount: Int
        ) {
            self.init(
                mergedDuration: mergedDuration,
                trimmedCount: trimmedCount,
                skippedCount: skippedCount,
                validatedOutputIdentity: nil,
                validatedOutputDigest: nil
            )
        }

        fileprivate init(
            mergedDuration: TimeInterval,
            trimmedCount: Int,
            skippedCount: Int,
            validatedOutputIdentity: SegmentObjectIdentity?,
            validatedOutputDigest: SHA256.Digest?
        ) {
            self.mergedDuration = mergedDuration
            self.trimmedCount = trimmedCount
            self.skippedCount = skippedCount
            self.validatedOutputIdentity = validatedOutputIdentity
            self.validatedOutputDigest = validatedOutputDigest
        }

        var completedFullValidation: Bool {
            validatedOutputIdentity != nil && validatedOutputDigest != nil
        }

        func validatedOutputMatches(
            _ fileStatus: stat,
            digest: SHA256.Digest
        ) -> Bool {
            validatedOutputIdentity?.matches(fileStatus, includingSize: true) == true
                && validatedOutputDigest == digest
        }
    }

    /// Merges segment files into a single output file.
    /// - Single segment: copies the file directly (no re-encoding).
    /// - Multiple segments: streams each segment through AVAssetReader → AVAssetWriter
    ///   so peak memory is O(1 segment), not O(N segments).
    /// - `timeoutSeconds`: maximum time allowed for the merge phase (default 300s).
    ///   If exceeded, `MergeError.exportTimedOut` is thrown.
    @discardableResult
    static func merge(segments: [URL], outputURL: URL, timeoutSeconds: Int = 300) async throws -> MergeResult {
        try await mergeImpl(
            segments: segments,
            outputURL: outputURL,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Pipeline-only entry point for private descriptor-copied inputs.
    static func mergeValidatedPrivateCopies(
        segments: [URL],
        outputURL: URL,
        timeoutSeconds: Int
    ) async throws -> MergeResult {
        try await mergeImpl(
            segments: segments,
            outputURL: outputURL,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func mergeImpl(
        segments: [URL],
        outputURL: URL,
        timeoutSeconds: Int
    ) async throws -> MergeResult {
        guard !segments.isEmpty else {
            throw MergeError.noSegments
        }

        guard timeoutSeconds > 0 else {
            throw MergeError.exportTimedOut(timeoutSeconds)
        }
        try Task.checkCancellation()

        // This API only accepts a guaranteed-new private staging URL. It never
        // removes or overwrites a caller-supplied path.
        var outputStatus = stat()
        guard Darwin.lstat(outputURL.path, &outputStatus) != 0, errno == ENOENT else {
            throw MergeError.outputAlreadyExists
        }

        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        var completed = false
        var createdOutputDescriptor: Int32?
        defer {
            if !completed, let createdOutputDescriptor {
                removeCreatedOutput(
                    at: outputURL,
                    descriptor: createdOutputDescriptor
                )
            }
            if let createdOutputDescriptor {
                _ = Darwin.close(createdOutputDescriptor)
            }
        }

        do {
            // Trailing-silence trim (spec 2026-07-06-silent-tail-handling): drop
            // fully-silent trailing segments before merging. Only multi-segment
            // recordings are trimmed; an all-silent recording merges unchanged and
            // is handled downstream by the empty-transcript auto-discard.
            var kept = segments
            var trimmedCount = 0
            if segments.count > 1 {
                (kept, trimmedCount) = await trimTrailingSilentSegments(segments)
            }
            try checkProgress(deadline: deadline, timeoutSeconds: timeoutSeconds)

            // Kept multi-segment inputs are decoded exactly once by
            // `streamSegment`. Inputs removed as trailing silence still belong
            // to the required source set, so explicitly decode those through
            // EOF before accepting the merge. This preserves fail-closed
            // corruption handling without an O(N) validation pass over every
            // segment before the real merge pass.
            for trimmedSegment in segments.suffix(trimmedCount) {
                _ = try await validateDecodableAudio(
                    at: trimmedSegment,
                    deadline: deadline,
                    timeoutSeconds: timeoutSeconds
                )
            }

            if kept.count == 1 {
                try FileManager.default.copyItem(at: kept[0], to: outputURL)
                let outputDescriptor = try openCreatedOutput(at: outputURL)
                createdOutputDescriptor = outputDescriptor
                let validationStart = try snapshotCreatedOutput(
                    at: outputURL,
                    descriptor: outputDescriptor,
                    deadline: deadline,
                    timeoutSeconds: timeoutSeconds
                )
                let duration = try await validateDecodableAudio(
                    descriptor: outputDescriptor,
                    deadline: deadline,
                    timeoutSeconds: timeoutSeconds
                )
                let validationEnd = try snapshotCreatedOutput(
                    at: outputURL,
                    descriptor: outputDescriptor,
                    deadline: deadline,
                    timeoutSeconds: timeoutSeconds
                )
                guard validationStart == validationEnd else {
                    throw MergeError.exportFailed("created output changed during validation")
                }
                completed = true
                return MergeResult(
                    mergedDuration: duration,
                    trimmedCount: trimmedCount,
                    skippedCount: 0,
                    validatedOutputIdentity: validationEnd.identity,
                    validatedOutputDigest: validationEnd.digest
                )
            }

            // Set up AVAssetWriter for M4A/AAC output
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
            } catch {
                throw MergeError.cannotCreateExportSession
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            writerInput.expectsMediaDataInRealTime = false

            guard writer.canAdd(writerInput) else {
                throw MergeError.cannotCreateTrack
            }
            writer.add(writerInput)

            let startedWriting = writer.startWriting()
            if startedWriting {
                createdOutputDescriptor = try openCreatedOutput(at: outputURL)
            }
            guard startedWriting else {
                throw MergeError.exportFailed(writer.error?.localizedDescription ?? "writer failed to start")
            }
            writer.startSession(atSourceTime: .zero)

            var cumulativeOffset = CMTime.zero

            for segmentURL in kept {
                do {
                    try checkProgress(deadline: deadline, timeoutSeconds: timeoutSeconds)
                    let segmentDuration = try await streamSegment(
                        url: segmentURL,
                        to: writerInput,
                        timeOffset: cumulativeOffset,
                        deadline: deadline
                    )
                    cumulativeOffset = CMTimeAdd(cumulativeOffset, segmentDuration)
                } catch {
                    writer.cancelWriting()
                    throw error
                }
            }

            guard cumulativeOffset.seconds.isFinite, cumulativeOffset.seconds > 0 else {
                writer.cancelWriting()
                throw MergeError.invalidAudio("merged duration is not positive")
            }

            // Finalize
            writerInput.markAsFinished()

            try checkProgress(deadline: deadline, timeoutSeconds: timeoutSeconds)
            let finishStart = ContinuousClock.now
            try await CancellableCallbackOperation.run(
                for: ContinuousClock.now.duration(to: deadline),
                start: { complete, _ in
                    writer.finishWriting {
                        _ = complete(.success(()))
                    }
                },
                cancel: {
                    writer.cancelWriting()
                }
            )
            let finishDuration = ContinuousClock.now - finishStart
            if finishDuration > .seconds(30) {
                let secs = Double(finishDuration.components.seconds) + Double(finishDuration.components.attoseconds) / 1e18
                NSLog("[AudioSegmentMerger] finishWriting took %.1fs (>30s)", secs)
            }

            guard isCompletedWriterStatus(writer.status) else {
                throw MergeError.exportFailed(
                    writer.error?.localizedDescription
                        ?? "writer ended with status \(writer.status.rawValue)"
                )
            }
            guard let createdOutputDescriptor,
                  createdOutputMatches(
                    at: outputURL,
                    descriptor: createdOutputDescriptor
                  ) else {
                throw MergeError.exportFailed("created output changed before validation")
            }
            try checkProgress(deadline: deadline, timeoutSeconds: timeoutSeconds)
            let validationStart = try snapshotCreatedOutput(
                at: outputURL,
                descriptor: createdOutputDescriptor,
                deadline: deadline,
                timeoutSeconds: timeoutSeconds
            )
            let outputDuration = try await validateDecodableAudio(
                descriptor: createdOutputDescriptor,
                deadline: deadline,
                timeoutSeconds: timeoutSeconds
            )
            let validationEnd = try snapshotCreatedOutput(
                at: outputURL,
                descriptor: createdOutputDescriptor,
                deadline: deadline,
                timeoutSeconds: timeoutSeconds
            )
            guard durationsMatch(
                outputDuration: outputDuration,
                expectedDuration: cumulativeOffset.seconds
            ), validationStart == validationEnd else {
                throw MergeError.exportFailed(
                    "created output changed or has incomplete duration"
                )
            }

            completed = true
            return MergeResult(
                mergedDuration: outputDuration,
                trimmedCount: trimmedCount,
                skippedCount: 0,
                validatedOutputIdentity: validationEnd.identity,
                validatedOutputDigest: validationEnd.digest
            )
        } catch is CancellationError {
            throw MergeError.exportCancelled
        }
    }

    /// Fully decodes an audio asset and returns its positive finite duration.
    /// This rejects metadata-only success for corrupt/truncated inputs.
    static func validateDecodableAudio(
        at url: URL,
        timeoutSeconds: Int = 300
    ) async throws -> TimeInterval {
        guard timeoutSeconds > 0 else {
            throw MergeError.exportTimedOut(timeoutSeconds)
        }
        return try await validateDecodableAudio(
            at: url,
            deadline: ContinuousClock.now + .seconds(timeoutSeconds),
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func validateDecodableAudio(
        at url: URL,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: Int
    ) async throws -> TimeInterval {
        try await validateDecodableAudio(
            asset: AVURLAsset(url: url),
            deadline: deadline,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Decode from the already-open file capability instead of reopening its
    /// pathname. This keeps the validated object stable even if another
    /// same-user process swaps names in the private staging directory.
    private static func validateDecodableAudio(
        descriptor: Int32,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: Int
    ) async throws -> TimeInterval {
        guard descriptor >= 0 else {
            throw MergeError.invalidAudio("output descriptor is invalid")
        }
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        return try await validateDecodableAudio(
            asset: AVURLAsset(
                url: descriptorURL,
                options: [AVURLAssetOverrideMIMETypeKey: "audio/mp4"]
            ),
            deadline: deadline,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func validateDecodableAudio(
        asset: AVURLAsset,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: Int
    ) async throws -> TimeInterval {
        try checkProgress(deadline: deadline, timeoutSeconds: timeoutSeconds)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw MergeError.invalidAudio("duration is not positive")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw MergeError.invalidAudio("asset contains no audio track")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MergeError.invalidAudio("reader cannot decode audio tracks")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MergeError.invalidAudio("reader failed to start")
        }

        var decodedSample = false
        while reader.status == .reading {
            do {
                try checkProgress(deadline: deadline, timeoutSeconds: timeoutSeconds)
            } catch {
                reader.cancelReading()
                throw error
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            decodedSample = decodedSample || CMSampleBufferGetNumSamples(sample) > 0
        }
        guard reader.status == .completed else {
            throw reader.error ?? MergeError.invalidAudio("reader did not decode through EOF")
        }
        guard decodedSample else {
            throw MergeError.invalidAudio("asset contains no decodable audio samples")
        }
        return duration
    }

    private static func checkProgress(
        deadline: ContinuousClock.Instant,
        timeoutSeconds: Int
    ) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw MergeError.exportTimedOut(timeoutSeconds)
        }
    }

    private struct CreatedOutputSnapshot: Equatable {
        let identity: SegmentObjectIdentity
        let digest: SHA256.Digest
    }

    /// Captures both the opened file's identity and its content while requiring
    /// the private output pathname to resolve to that same file before and
    /// after hashing. Comparing snapshots around the decode binds validation
    /// proof to the exact bytes that remained stable through that decode.
    private static func snapshotCreatedOutput(
        at url: URL,
        descriptor: Int32?,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: Int
    ) throws -> CreatedOutputSnapshot {
        guard let descriptor,
              createdOutputMatches(at: url, descriptor: descriptor) else {
            throw MergeError.exportFailed("created output changed during validation")
        }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw MergeError.exportFailed("created output cannot be inspected")
        }
        let identity = SegmentObjectIdentity(fileStatus)
        let digest = try streamingDigest(
            descriptor: descriptor,
            deadline: deadline,
            timeoutSeconds: timeoutSeconds
        )
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              identity.matches(finalStatus, includingSize: true),
              createdOutputMatches(at: url, descriptor: descriptor) else {
            throw MergeError.exportFailed("created output changed during validation")
        }
        return CreatedOutputSnapshot(identity: identity, digest: digest)
    }

    private static func streamingDigest(
        descriptor: Int32,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: Int
    ) throws -> SHA256.Digest {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw MergeError.exportFailed("created output cannot be hashed")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkProgress(deadline: deadline, timeoutSeconds: timeoutSeconds)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw MergeError.exportFailed("created output cannot be hashed")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize()
    }

    /// AAC framing/container rounding can move duration by a few samples, but
    /// a fully decodable prefix must never be accepted as a complete merge.
    static func durationsMatch(
        outputDuration: TimeInterval,
        expectedDuration: TimeInterval
    ) -> Bool {
        let maximumAACContainerDrift: TimeInterval = 0.1
        return outputDuration.isFinite
            && expectedDuration.isFinite
            && outputDuration > 0
            && expectedDuration > 0
            && abs(outputDuration - expectedDuration) <= maximumAACContainerDrift
    }

    static func isCompletedWriterStatus(_ status: AVAssetWriter.Status) -> Bool {
        status == .completed
    }

    private static func openCreatedOutput(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw MergeError.exportFailed("created output cannot be reopened safely")
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == Darwin.geteuid(),
              status.st_nlink == 1 else {
            _ = Darwin.close(descriptor)
            throw MergeError.exportFailed("created output is not an owned single-link file")
        }
        return descriptor
    }

    private static func removeCreatedOutput(
        at url: URL,
        descriptor: Int32
    ) {
        var openedStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              openedStatus.st_uid == Darwin.geteuid(),
              openedStatus.st_nlink == 1,
              Darwin.lstat(url.path, &pathStatus) == 0,
              pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              pathStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_nlink == 1,
              SegmentObjectIdentity(openedStatus).matches(
                pathStatus,
                includingSize: true
              ) else {
            return
        }
        _ = Darwin.unlink(url.path)
    }

    private static func createdOutputMatches(
        at url: URL,
        descriptor: Int32
    ) -> Bool {
        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              openedStatus.st_uid == Darwin.geteuid(),
              openedStatus.st_nlink == 1 else { return false }

        let pathDescriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard pathDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(pathDescriptor) }
        var pathStatus = stat()
        return Darwin.fstat(pathDescriptor, &pathStatus) == 0
            && pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && pathStatus.st_uid == Darwin.geteuid()
            && pathStatus.st_nlink == 1
            && SegmentObjectIdentity(openedStatus).matches(
                pathStatus,
                includingSize: true
            )
    }

    /// Walks the segment list from the end, dropping segments with no audible
    /// content (per-track, windowed — see AudioSilenceDetector). Stops at the
    /// first audible segment, so cost is proportional to the silent tail. If
    /// EVERY segment is silent the list is returned unchanged — that recording
    /// belongs to the downstream empty-transcript discard, not to trim.
    static func trimTrailingSilentSegments(_ segments: [URL]) async -> (kept: [URL], trimmedCount: Int) {
        var silentTail = 0
        for url in segments.reversed() {
            if await AudioSilenceDetector.hasAudibleContent(at: url) { break }
            silentTail += 1
        }
        guard silentTail > 0, silentTail < segments.count else {
            if silentTail == segments.count {
                NSLog("[Cadenza] AudioSegmentMerger: all %d segments silent — not trimming", segments.count)
            }
            return (segments, 0)
        }
        NSLog("[Cadenza] AudioSegmentMerger: trimming %d trailing silent segment(s) of %d",
              silentTail, segments.count)
        return (Array(segments.dropLast(silentTail)), silentTail)
    }

    // MARK: - Per-segment streaming

    /// Streams all audio buffers from one segment file into the writer input,
    /// adjusting timestamps by `timeOffset`. Returns the segment's duration.
    private static func streamSegment(
        url: URL,
        to writerInput: AVAssetWriterInput,
        timeOffset: CMTime,
        deadline: ContinuousClock.Instant
    ) async throws -> CMTime {
        let asset = AVURLAsset(url: url)

        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            throw MergeError.invalidAudio("segment duration is not positive")
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw MergeError.invalidAudio("segment contains no audio track")
        }

        // Read as decompressed PCM (Float32) so the writer can re-encode to AAC.
        // Use AVAssetReaderAudioMixOutput to merge all tracks (system + mic) into one.
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw NSError(domain: "AudioSegmentMerger", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"])
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "AudioSegmentMerger", code: -2,
                                          userInfo: [NSLocalizedDescriptionKey: "Reader failed to start"])
        }

        // Stream buffers. A metadata duration and audio track are not enough:
        // every required kept segment must contribute decodable samples before
        // the merge can carry complete-validation proof.
        var decodedSample = false
        while reader.status == .reading {
            // Check timeout periodically
            if ContinuousClock.now >= deadline {
                reader.cancelReading()
                throw MergeError.exportTimedOut(0)
            }

            try Task.checkCancellation()

            // Wait for writer to be ready
            if !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                continue
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break
            }
            decodedSample = decodedSample || CMSampleBufferGetNumSamples(sampleBuffer) > 0

            let retimed = try retimestamp(sampleBuffer: sampleBuffer, offset: timeOffset)
            if !writerInput.append(retimed) {
                reader.cancelReading()
                throw MergeError.exportFailed("writer rejected sample buffer at offset \(timeOffset.seconds)s")
            }
        }

        guard reader.status == .completed else {
            throw reader.error ?? NSError(domain: "AudioSegmentMerger", code: -3,
                                          userInfo: [NSLocalizedDescriptionKey: "Reader did not reach EOF"])
        }
        guard decodedSample else {
            throw MergeError.invalidAudio("segment contains no decodable audio samples")
        }

        return duration
    }

    // MARK: - Retimestamping

    /// Returns a new CMSampleBuffer with presentation timestamps shifted by `offset`.
    static func retimestamp(sampleBuffer: CMSampleBuffer, offset: CMTime) throws -> CMSampleBuffer {
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return sampleBuffer }

        // Build new timing array with offset applied
        var timingInfoCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingInfoCount)

        var timingInfos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingInfoCount)
        let status1 = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timingInfoCount, arrayToFill: &timingInfos, entriesNeededOut: nil)
        guard status1 == noErr else {
            throw MergeError.exportFailed("failed to get timing info: \(status1)")
        }

        for i in 0..<timingInfos.count {
            timingInfos[i].presentationTimeStamp = CMTimeAdd(timingInfos[i].presentationTimeStamp, offset)
            if timingInfos[i].decodeTimeStamp.isValid && timingInfos[i].decodeTimeStamp != .invalid {
                timingInfos[i].decodeTimeStamp = CMTimeAdd(timingInfos[i].decodeTimeStamp, offset)
            }
        }

        var newBuffer: CMSampleBuffer?
        let status2 = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingInfoCount,
            sampleTimingArray: &timingInfos,
            sampleBufferOut: &newBuffer
        )
        guard status2 == noErr, let result = newBuffer else {
            throw MergeError.exportFailed("failed to create retimestamped buffer: \(status2)")
        }

        return result
    }

    /// Compatibility entry point retained for the capture seam. Source
    /// inventories are deliberately preserved until Task 3 can remove only an
    /// identity-bound exact set after a durable Store commit.
    static func cleanupSegments(directory: URL) {
        NSLog(
            "[AudioSegmentMerger] preserving source inventory pending exact cleanup: %@",
            directory.lastPathComponent
        )
    }

    enum MergeError: Error, LocalizedError {
        case noSegments
        case cannotCreateTrack
        case cannotCreateExportSession
        case exportFailed(String)
        case exportCancelled
        case exportTimedOut(Int)
        case outputAlreadyExists
        case invalidAudio(String)

        var errorDescription: String? {
            switch self {
            case .noSegments: return "No segments to merge"
            case .cannotCreateTrack: return "Cannot create composition track"
            case .cannotCreateExportSession: return "Cannot create export session"
            case .exportFailed(let reason): return "Export failed: \(reason)"
            case .exportCancelled: return "Export was cancelled"
            case .exportTimedOut(let seconds): return "Export timed out after \(seconds)s"
            case .outputAlreadyExists: return "Output already exists"
            case .invalidAudio(let reason): return "Invalid audio: \(reason)"
            }
        }
    }
}
