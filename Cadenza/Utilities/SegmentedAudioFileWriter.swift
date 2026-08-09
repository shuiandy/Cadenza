import Darwin
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

enum SegmentManifestValidation: Sendable {
    case trusted(TrustedSegmentSet)
    case trustFailure(String)
}

enum TrustedSegmentCopyError: Error, LocalizedError, Sendable {
    case sourceTrustChanged
    case invalidDestination
    case copyFailed
    case copyTimedOut

    var errorDescription: String? {
        switch self {
        case .sourceTrustChanged:
            return "A trusted segment changed before its private copy"
        case .invalidDestination:
            return "The private staging destination is invalid"
        case .copyFailed:
            return "A trusted segment could not be copied completely"
        case .copyTimedOut:
            return "Copying trusted segments into private staging timed out"
        }
    }
}

fileprivate struct TrustedSegmentFile: Sendable {
    let index: Int
    let basename: String
    let identity: SegmentObjectIdentity
}

fileprivate struct TrustedPrivateSegmentFile: Sendable {
    let basename: String
    let identity: SegmentObjectIdentity
}

/// Opaque identity-bound inventory of private staged copies. Construction is
/// confined to the descriptor-copy implementation so a bare URL can never be
/// promoted to trusted staged input by a caller.
struct TrustedPrivateSegmentSet: Sendable {
    fileprivate let directoryURL: URL
    fileprivate let directoryIdentity: SegmentObjectIdentity
    fileprivate let files: [TrustedPrivateSegmentFile]

    fileprivate init(
        directoryURL: URL,
        directoryIdentity: SegmentObjectIdentity,
        files: [TrustedPrivateSegmentFile]
    ) {
        self.directoryURL = directoryURL
        self.directoryIdentity = directoryIdentity
        self.files = files
    }

    var count: Int { files.count }

    func decodingURL(at index: Int) -> URL {
        directoryURL.appendingPathComponent(files[index].basename)
    }

    func decodingURLs() -> [URL] {
        files.map { directoryURL.appendingPathComponent($0.basename) }
    }
}

/// Identity-bound result of validating one complete manifest and its exact
/// directory inventory. Construction stays private to this file so callers
/// cannot mint trust from bare URLs.
struct TrustedSegmentSet: Sendable {
    fileprivate let authority: SegmentStorageAuthority
    fileprivate let directoryIdentity: SegmentObjectIdentity
    fileprivate let manifestIdentity: SegmentObjectIdentity
    fileprivate let segmentFiles: [TrustedSegmentFile]
    let recordingID: UUID
    let segmentsDirectory: URL
    let manifest: SegmentedAudioFileWriter.SegmentManifest

    fileprivate init(
        authority: SegmentStorageAuthority,
        directoryIdentity: SegmentObjectIdentity,
        manifestIdentity: SegmentObjectIdentity,
        segmentFiles: [TrustedSegmentFile],
        recordingID: UUID,
        segmentsDirectory: URL,
        manifest: SegmentedAudioFileWriter.SegmentManifest
    ) {
        self.authority = authority
        self.directoryIdentity = directoryIdentity
        self.manifestIdentity = manifestIdentity
        self.segmentFiles = segmentFiles
        self.recordingID = recordingID
        self.segmentsDirectory = segmentsDirectory
        self.manifest = manifest
    }

    var count: Int { segmentFiles.count }

    var storageAuthority: SegmentStorageAuthority { authority }

    /// Temporary Task 0 merger bridge. Callers cannot construct this token;
    /// Task 2 replaces path reopening with verified private staging copies.
    func legacySegmentURLsForMerge() -> [URL] {
        segmentFiles.map { segmentsDirectory.appendingPathComponent($0.basename) }
    }
}

/// Manages segmented audio recording with dual-writer overlap for zero-gap segment rotation.
/// Each segment is written to a separate .m4a file. A manifest (segments.json) tracks all segments.
/// Crash recovery: on app restart, the manifest lists all completed segments for merging.
final class SegmentedAudioFileWriter: @unchecked Sendable {

    typealias ManifestDataWriter = @Sendable (Data, URL) throws -> Void

    // MARK: - Manifest Types

    struct SegmentEntry: Codable, Sendable {
        let index: Int
        let filename: String
        let startedAt: Date
        var completedAt: Date?
    }

    struct SegmentManifest: Codable, Sendable {
        let recordingID: String
        var segments: [SegmentEntry]
        var isComplete: Bool
    }

    // MARK: - Configuration

    static let segmentDuration: TimeInterval = 30

    // MARK: - State

    private let queue = DispatchQueue(label: "com.shuiandy.Cadenza.segmentedWriter")

    private var segmentsDirectory: URL?
    private var recordingID: UUID?
    private var activeWriter: AudioFileWriter?
    private var retiringWriter: AudioFileWriter?
    private var segmentIndex = 0
    private var manifest = SegmentManifest(recordingID: "", segments: [], isComplete: false)
    private var rotationTimer: DispatchSourceTimer?
    private var isActive = false
    private var storedSampleRate: Double = 48000
    private var storedChannels: UInt32 = 1
    private var hasReportedManifestFailure = false
    private let manifestDataWriter: ManifestDataWriter

    /// Propagated to each AudioFileWriter created during this session.
    /// Segment-writer failures keep their existing per-writer behavior; manifest
    /// persistence failures are coalesced to one callback per recording session.
    var onWriterFailure: (@Sendable (String) -> Void)?

    init(
        manifestDataWriter: @escaping ManifestDataWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.manifestDataWriter = manifestDataWriter
    }

    // MARK: - Start

    func startWriting(segmentsDir: URL, recordingID: UUID, sampleRate: Double = 48000, channels: UInt32 = 1) throws {
        try queue.sync {
            guard !isActive else { return }

            try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

            self.segmentsDirectory = segmentsDir
            self.recordingID = recordingID
            self.segmentIndex = 0
            self.storedSampleRate = sampleRate
            self.storedChannels = channels
            self.hasReportedManifestFailure = false

            // Start first segment
            let writer = AudioFileWriter()
            writer.onWriterFailure = self.onWriterFailure
            let filename = segmentFilename(index: 0)
            let url = segmentsDir.appendingPathComponent(filename)
            let initialManifest = SegmentManifest(
                recordingID: recordingID.uuidString,
                segments: [
                    SegmentEntry(index: 0, filename: filename, startedAt: Date())
                ],
                isComplete: false
            )

            do {
                try writer.startWriting(to: url, sampleRate: sampleRate, channels: channels)
                try writeManifestSync(initialManifest, in: segmentsDir)
            } catch {
                writer.forceReset()
                removeUncommittedSegment(at: url)
                resetSessionState()
                throw error
            }

            self.manifest = initialManifest
            self.activeWriter = writer
            self.retiringWriter = nil
            self.isActive = true

            startRotationTimer()
        }
    }

    // MARK: - Append Audio

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [weak self] in
            guard let self else { return }
            self.activeWriter?.appendSystemAudio(buffer)
            self.retiringWriter?.appendSystemAudio(buffer)
        }
    }

    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [weak self] in
            guard let self else { return }
            self.activeWriter?.appendMicrophoneAudio(buffer)
            self.retiringWriter?.appendMicrophoneAudio(buffer)
        }
    }

    // MARK: - Rotation

    private func startRotationTimer() {
        rotationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.segmentDuration,
            repeating: Self.segmentDuration
        )
        timer.setEventHandler { [weak self] in
            self?.rotateSegment()
        }
        timer.resume()
        rotationTimer = timer
    }

    /// Dual-writer overlap rotation:
    /// 1. Create new writer B, start writing to it
    /// 2. Move current writer A to `retiringWriter`
    /// 3. Stop A in background (its appendBuffer safely drops buffers once status != .writing)
    private func rotateSegment() {
        // Already on `queue`
        guard isActive, let segDir = segmentsDirectory else { return }

        let newIndex = segmentIndex + 1
        let newFilename = segmentFilename(index: newIndex)
        let newURL = segDir.appendingPathComponent(newFilename)

        let newWriter = AudioFileWriter()
        newWriter.onWriterFailure = self.onWriterFailure
        do {
            try newWriter.startWriting(to: newURL, sampleRate: storedSampleRate, channels: storedChannels)
        } catch {
            NSLog("[Cadenza] SegmentedWriter: failed to start segment %d: %@", newIndex, error.localizedDescription)
            newWriter.forceReset()
            removeUncommittedSegment(at: newURL)
            return
        }

        let entry = SegmentEntry(index: newIndex, filename: newFilename, startedAt: Date())
        var candidateManifest = manifest
        candidateManifest.segments.append(entry)

        do {
            try writeManifestSync(candidateManifest, in: segDir)
        } catch {
            newWriter.forceReset()
            removeUncommittedSegment(at: newURL)
            reportManifestFailureOnce(operation: "segment rotation", error: error)
            return
        }

        // Retire old writer
        let oldWriter = activeWriter
        let oldIndex = newIndex - 1
        let sessionID = recordingID
        segmentIndex = newIndex
        manifest = candidateManifest
        retiringWriter = oldWriter
        activeWriter = newWriter

        // Stop old writer in background
        Task { [weak self] in
            _ = await oldWriter?.stopWriting()
            self?.queue.async { [weak self] in
                guard let self else { return }
                guard self.recordingID == sessionID else { return }
                // Mark segment as completed in manifest
                if let idx = self.manifest.segments.firstIndex(where: { $0.index == oldIndex }) {
                    var candidateManifest = self.manifest
                    candidateManifest.segments[idx].completedAt = Date()
                    do {
                        try self.writeManifestSync(candidateManifest, in: segDir)
                        self.manifest = candidateManifest
                    } catch {
                        self.reportManifestFailureOnce(
                            operation: "segment completion",
                            error: error
                        )
                    }
                }
                // Clear retiring if it's still the same writer
                if self.retiringWriter === oldWriter {
                    self.retiringWriter = nil
                }
            }
        }
    }

    // MARK: - Stop

    /// Stops all writers and returns URLs of all segment files.
    func stopWriting() async -> [URL] {
        // Step 1: Capture state on the serial queue synchronously
        let (active, retiring, segDir) = queue.sync { () -> (AudioFileWriter?, AudioFileWriter?, URL?) in
            guard isActive else { return (nil, nil, nil) }

            rotationTimer?.cancel()
            rotationTimer = nil
            isActive = false

            let a = activeWriter
            let r = retiringWriter
            activeWriter = nil
            retiringWriter = nil

            return (a, r, segmentsDirectory)
        }

        guard segDir != nil else { return [] }

        // Step 2: Stop both writers concurrently (no nesting — pure async/await)
        async let activeStop: URL? = active?.stopWriting()
        async let retiringStop: URL? = retiring?.stopWriting()
        _ = await (activeStop, retiringStop)

        // Step 3: Finalize manifest on the serial queue
        let urls = queue.sync { () -> [URL] in
            let now = Date()
            var candidateManifest = manifest
            for i in candidateManifest.segments.indices
                where candidateManifest.segments[i].completedAt == nil {
                candidateManifest.segments[i].completedAt = now
            }
            candidateManifest.isComplete = true

            if let segDir {
                do {
                    try writeManifestSync(candidateManifest, in: segDir)
                    manifest = candidateManifest
                } catch {
                    reportManifestFailureOnce(operation: "recording stop", error: error)
                }
            }

            guard let segDir else { return [] }
            return manifest.segments.compactMap { entry -> URL? in
                let url = segDir.appendingPathComponent(entry.filename)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }

        return urls
    }

    /// Force-reset all state without waiting for writers to finish.
    /// Writes a final manifest so crash recovery can find completed segments.
    func forceReset() {
        queue.sync { [self] in
            NSLog("[Cadenza] SegmentedWriter.forceReset: forcibly clearing state")
            rotationTimer?.cancel()
            rotationTimer = nil

            activeWriter?.forceReset()
            retiringWriter?.forceReset()
            activeWriter = nil
            retiringWriter = nil

            var candidateManifest = manifest
            candidateManifest.isComplete = false
            if let segDir = segmentsDirectory {
                do {
                    try writeManifestSync(candidateManifest, in: segDir)
                    manifest = candidateManifest
                } catch {
                    reportManifestFailureOnce(operation: "forced reset", error: error)
                }
            }

            isActive = false
        }
    }

    // MARK: - Private

    /// Must be called on `queue`.
    private func writeManifestSync(_ candidateManifest: SegmentManifest, in segDir: URL) throws {
        let manifestURL = segDir.appendingPathComponent("segments.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(candidateManifest)

        // .atomic writes to a temp file then renames — crash-safe
        try manifestDataWriter(data, manifestURL)
    }

    /// Must be called on `queue`.
    private func reportManifestFailureOnce(operation: String, error: Error) {
        NSLog(
            "[Cadenza] SegmentedWriter: manifest write failed during %@: %@",
            operation,
            error.localizedDescription
        )
        guard !hasReportedManifestFailure else { return }
        hasReportedManifestFailure = true
        // The detailed filesystem error is already in the local diagnostic log.
        // Higher layers need only a stable failure signal; forwarding an OS
        // description can duplicate paths or other diagnostics into UI logs.
        onWriterFailure?("Segment manifest write failed during \(operation)")
    }

    /// Must be called on `queue` after the writer has released the file.
    private func removeUncommittedSegment(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog(
                "[Cadenza] SegmentedWriter: failed to remove uncommitted segment %@: %@",
                url.path,
                error.localizedDescription
            )
        }
    }

    /// Must be called on `queue`.
    private func resetSessionState() {
        rotationTimer?.cancel()
        rotationTimer = nil
        segmentsDirectory = nil
        recordingID = nil
        activeWriter = nil
        retiringWriter = nil
        segmentIndex = 0
        manifest = SegmentManifest(recordingID: "", segments: [], isComplete: false)
        isActive = false
    }

#if DEBUG
    /// Deterministic rotation seam for failure-path tests; production rotates via its timer.
    func rotateSegmentForTesting() {
        queue.sync { [self] in
            rotateSegment()
        }
    }
#endif

    private func segmentFilename(index: Int) -> String {
        String(format: "segment-%03d.m4a", index)
    }
}

// MARK: - Recovery Manifest Validation

extension SegmentedAudioFileWriter {
    static let maximumRecoveryManifestBytes: Int64 = 256 * 1_024

    static func validateManifest(
        recordingID: UUID,
        segmentsDirectory: URL,
        authority: SegmentStorageAuthority
    ) -> SegmentManifestValidation {
        guard authority.authorizes(
            segmentsDirectory: segmentsDirectory,
            recordingID: recordingID
        ) else {
            return .trustFailure("Segments directory is outside its explicit authority")
        }
        guard let directoryDescriptor = openRecordingDirectory(
            recordingID: recordingID,
            authority: authority
        ) else {
            return .trustFailure("Unable to open the authorized segments directory")
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
              isDirectory(directoryStatus) else {
            return .trustFailure("Segments directory is not a directory")
        }
        let directoryIdentity = SegmentObjectIdentity(directoryStatus)

        let manifestDescriptor = Darwin.openat(
            directoryDescriptor,
            "segments.json",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard manifestDescriptor >= 0 else {
            return .trustFailure("Manifest cannot be opened without following links")
        }
        defer { _ = Darwin.close(manifestDescriptor) }

        var manifestStatus = stat()
        guard Darwin.fstat(manifestDescriptor, &manifestStatus) == 0,
              isOwnedSingleLinkRegularFile(manifestStatus),
              manifestStatus.st_size > 0,
              manifestStatus.st_size <= maximumRecoveryManifestBytes else {
            return .trustFailure("Manifest is not a bounded owned single-link file")
        }
        let manifestIdentity = SegmentObjectIdentity(manifestStatus)
        guard let manifestData = readExactly(
            descriptor: manifestDescriptor,
            expectedIdentity: manifestIdentity,
            maximumBytes: maximumRecoveryManifestBytes
        ) else {
            return .trustFailure("Manifest changed while it was read")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(SegmentManifest.self, from: manifestData),
              manifest.recordingID == recordingID.uuidString,
              !manifest.segments.isEmpty else {
            return .trustFailure("Manifest content does not match the recording")
        }

        var expectedInventory: Set<String> = ["segments.json"]
        var trustedFiles: [TrustedSegmentFile] = []
        trustedFiles.reserveCapacity(manifest.segments.count)

        for (expectedIndex, entry) in manifest.segments.enumerated() {
            let expectedBasename = deterministicSegmentFilename(index: expectedIndex)
            guard entry.index == expectedIndex,
                  entry.filename == expectedBasename else {
                return .trustFailure("Manifest entries are not ordered deterministic basenames")
            }
            expectedInventory.insert(expectedBasename)

            var pathStatus = stat()
            guard Darwin.fstatat(
                directoryDescriptor,
                expectedBasename,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  isOwnedSingleLinkRegularFile(pathStatus),
                  pathStatus.st_size > 0 else {
                return .trustFailure(
                    "A required segment is missing or not an owned single-link file"
                )
            }

            let segmentDescriptor = Darwin.openat(
                directoryDescriptor,
                expectedBasename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard segmentDescriptor >= 0 else {
                return .trustFailure("A required segment cannot be opened without following links")
            }
            var openedStatus = stat()
            let inspected = Darwin.fstat(segmentDescriptor, &openedStatus) == 0
            _ = Darwin.close(segmentDescriptor)
            let identity = SegmentObjectIdentity(pathStatus)
            guard inspected,
                  isOwnedSingleLinkRegularFile(openedStatus),
                  openedStatus.st_size > 0,
                  identity.matches(openedStatus, includingSize: true) else {
                return .trustFailure("A required segment changed while it was inspected")
            }
            trustedFiles.append(
                TrustedSegmentFile(
                    index: expectedIndex,
                    basename: expectedBasename,
                    identity: identity
                )
            )
        }

        guard directoryEntryNames(descriptor: directoryDescriptor) == expectedInventory else {
            return .trustFailure("Segments directory contains an unexpected inventory")
        }
        var finalDirectoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &finalDirectoryStatus) == 0,
              directoryIdentity.matches(finalDirectoryStatus, includingSize: false) else {
            return .trustFailure("Segments directory changed during validation")
        }

        return .trusted(
            TrustedSegmentSet(
                authority: authority,
                directoryIdentity: directoryIdentity,
                manifestIdentity: manifestIdentity,
                segmentFiles: trustedFiles,
                recordingID: recordingID,
                segmentsDirectory: authority.expectedSegmentsDirectory(recordingID: recordingID),
                manifest: manifest
            )
        )
    }

    static func recheckForMerge(_ trustedSegments: TrustedSegmentSet) -> Bool {
        guard let directoryDescriptor = openRecordingDirectory(
            recordingID: trustedSegments.recordingID,
            authority: trustedSegments.authority
        ) else { return false }
        defer { _ = Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
              trustedSegments.directoryIdentity.matches(
                directoryStatus,
                includingSize: false
              ) else { return false }

        let expectedInventory = Set(
            ["segments.json"] + trustedSegments.segmentFiles.map(\.basename)
        )
        guard directoryEntryNames(descriptor: directoryDescriptor) == expectedInventory else {
            return false
        }

        let manifestDescriptor = Darwin.openat(
            directoryDescriptor,
            "segments.json",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard manifestDescriptor >= 0 else { return false }
        var manifestStatus = stat()
        let manifestMatches = Darwin.fstat(manifestDescriptor, &manifestStatus) == 0
            && isOwnedSingleLinkRegularFile(manifestStatus)
            && trustedSegments.manifestIdentity.matches(
                manifestStatus,
                includingSize: true
            )
        _ = Darwin.close(manifestDescriptor)
        guard manifestMatches else { return false }

        for trustedFile in trustedSegments.segmentFiles {
            var pathStatus = stat()
            guard Darwin.fstatat(
                directoryDescriptor,
                trustedFile.basename,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  isOwnedSingleLinkRegularFile(pathStatus),
                  pathStatus.st_size > 0,
                  trustedFile.identity.matches(pathStatus, includingSize: true) else {
                return false
            }

            let descriptor = Darwin.openat(
                directoryDescriptor,
                trustedFile.basename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else { return false }
            var openedStatus = stat()
            let matches = Darwin.fstat(descriptor, &openedStatus) == 0
                && isOwnedSingleLinkRegularFile(openedStatus)
                && trustedFile.identity.matches(openedStatus, includingSize: true)
            _ = Darwin.close(descriptor)
            guard matches else { return false }
        }
        return true
    }

    /// Removes only the manifest and segment objects whose identities were
    /// captured by manifest validation. Any replacement or unexpected entry is
    /// preserved for recovery instead of being adopted by path.
    static func cleanupTrustedSegments(
        _ trustedSegments: TrustedSegmentSet
    ) -> RecordingAudioCleanupResult {
        let rootDescriptor = Darwin.open(
            trustedSegments.authority.openedRootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            return .preserved("Segment storage authority cannot be reopened")
        }
        defer { _ = Darwin.close(rootDescriptor) }

        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0,
              isDirectory(rootStatus),
              trustedSegments.authority.rootIdentity.matches(
                rootStatus,
                includingSize: false
              ) else {
            return .preserved("Segment storage authority changed before cleanup")
        }

        let segmentsDescriptor = Darwin.openat(
            rootDescriptor,
            "segments",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if segmentsDescriptor < 0, errno == ENOENT {
            return .alreadyClean
        }
        guard segmentsDescriptor >= 0 else {
            return .preserved("Segments container cannot be reopened without following links")
        }
        defer { _ = Darwin.close(segmentsDescriptor) }

        let directoryBasename = trustedSegments.recordingID.uuidString
        let directoryDescriptor = Darwin.openat(
            segmentsDescriptor,
            directoryBasename,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if directoryDescriptor < 0, errno == ENOENT {
            return .alreadyClean
        }
        guard directoryDescriptor >= 0 else {
            return .preserved("Recording segments directory cannot be reopened without following links")
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        var directoryPathStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
              isDirectory(directoryStatus),
              trustedSegments.directoryIdentity.matches(
                directoryStatus,
                includingSize: false
              ),
              Darwin.fstatat(
                segmentsDescriptor,
                directoryBasename,
                &directoryPathStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              trustedSegments.directoryIdentity.matches(
                directoryPathStatus,
                includingSize: false
              ) else {
            return .preserved("Recording segments directory identity changed before cleanup")
        }

        let expectedFiles = trustedSegments.segmentFiles.map {
            ($0.basename, $0.identity)
        } + [("segments.json", trustedSegments.manifestIdentity)]
        var openedFiles: [(basename: String, identity: SegmentObjectIdentity, descriptor: Int32)] = []
        defer {
            for openedFile in openedFiles {
                _ = Darwin.close(openedFile.descriptor)
            }
        }

        // Open and bind every expected object before deleting any of them. A
        // deterministic replacement therefore preserves the entire remaining
        // recovery inventory.
        for (basename, identity) in expectedFiles {
            let descriptor = Darwin.openat(
                directoryDescriptor,
                basename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else {
                return .preserved("A trusted segment source changed before cleanup")
            }
            openedFiles.append((basename, identity, descriptor))

            var openedStatus = stat()
            var pathStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                  isOwnedSingleLinkRegularFile(openedStatus),
                  identity.matches(openedStatus, includingSize: true),
                  Darwin.fstatat(
                    directoryDescriptor,
                    basename,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  isOwnedSingleLinkRegularFile(pathStatus),
                  identity.matches(pathStatus, includingSize: true) else {
                return .preserved("A trusted segment source identity changed before cleanup")
            }
        }

        for openedFile in openedFiles {
            var openedStatus = stat()
            var pathStatus = stat()
            guard Darwin.fstat(openedFile.descriptor, &openedStatus) == 0,
                  isOwnedSingleLinkRegularFile(openedStatus),
                  openedFile.identity.matches(openedStatus, includingSize: true),
                  Darwin.fstatat(
                    directoryDescriptor,
                    openedFile.basename,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  isOwnedSingleLinkRegularFile(pathStatus),
                  openedFile.identity.matches(pathStatus, includingSize: true),
                  Darwin.unlinkat(
                    directoryDescriptor,
                    openedFile.basename,
                    0
                  ) == 0 else {
                return .preserved("A trusted segment source could not be removed exactly")
            }
        }

        guard Darwin.fsync(directoryDescriptor) == 0 else {
            return .preserved("Segment source removal could not be made durable")
        }

        var finalDirectoryStatus = stat()
        guard Darwin.fstatat(
            segmentsDescriptor,
            directoryBasename,
            &finalDirectoryStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              trustedSegments.directoryIdentity.matches(
                finalDirectoryStatus,
                includingSize: false
              ) else {
            return .preserved("Recording segments directory changed during cleanup")
        }
        guard Darwin.unlinkat(
            segmentsDescriptor,
            directoryBasename,
            AT_REMOVEDIR
        ) == 0 else {
            if errno == ENOTEMPTY || errno == EEXIST {
                return .preserved("Unexpected segment artifacts were preserved")
            }
            return .preserved("Recording segments directory could not be removed exactly")
        }
        guard Darwin.fsync(segmentsDescriptor) == 0,
              Darwin.fsync(rootDescriptor) == 0 else {
            return .preserved("Segment directory removal could not be made durable")
        }
        return .cleaned
    }

    /// Reopens every trusted source with no-follow semantics and copies its
    /// bytes through the verified descriptor into a caller-owned private
    /// directory. On any failure, only copies created by this invocation are
    /// unlinked; the trusted source inventory is never mutated.
    static func copyVerifiedSegments(
        _ trustedSegments: TrustedSegmentSet,
        to destinationDirectoryDescriptor: Int32,
        destinationDirectoryURL: URL,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> TrustedPrivateSegmentSet {
        var destinationStatus = stat()
        guard Darwin.fstat(destinationDirectoryDescriptor, &destinationStatus) == 0,
              isDirectory(destinationStatus),
              destinationStatus.st_uid == Darwin.geteuid(),
              destinationStatus.st_mode & mode_t(0o077) == 0 else {
            throw TrustedSegmentCopyError.invalidDestination
        }
        let destinationIdentity = SegmentObjectIdentity(destinationStatus)

        guard let sourceDirectoryDescriptor = openRecordingDirectory(
            recordingID: trustedSegments.recordingID,
            authority: trustedSegments.authority
        ) else {
            throw TrustedSegmentCopyError.sourceTrustChanged
        }
        defer { _ = Darwin.close(sourceDirectoryDescriptor) }

        var sourceDirectoryStatus = stat()
        let expectedInventory = Set(
            ["segments.json"] + trustedSegments.segmentFiles.map(\.basename)
        )
        guard Darwin.fstat(sourceDirectoryDescriptor, &sourceDirectoryStatus) == 0,
              trustedSegments.directoryIdentity.matches(
                sourceDirectoryStatus,
                includingSize: false
              ),
              directoryEntryNames(descriptor: sourceDirectoryDescriptor) == expectedInventory else {
            throw TrustedSegmentCopyError.sourceTrustChanged
        }

        let manifestDescriptor = Darwin.openat(
            sourceDirectoryDescriptor,
            "segments.json",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard manifestDescriptor >= 0 else {
            throw TrustedSegmentCopyError.sourceTrustChanged
        }
        var manifestStatus = stat()
        let manifestMatches = Darwin.fstat(manifestDescriptor, &manifestStatus) == 0
            && isOwnedSingleLinkRegularFile(manifestStatus)
            && trustedSegments.manifestIdentity.matches(
                manifestStatus,
                includingSize: true
            )
        _ = Darwin.close(manifestDescriptor)
        guard manifestMatches else {
            throw TrustedSegmentCopyError.sourceTrustChanged
        }

        var createdFiles: [TrustedPrivateSegmentFile] = []
        do {
            for trustedFile in trustedSegments.segmentFiles {
                try checkCopyProgress(deadline: deadline)
                let sourceDescriptor = Darwin.openat(
                    sourceDirectoryDescriptor,
                    trustedFile.basename,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
                guard sourceDescriptor >= 0 else {
                    throw TrustedSegmentCopyError.sourceTrustChanged
                }
                defer { _ = Darwin.close(sourceDescriptor) }

                var sourceStatus = stat()
                guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
                      isOwnedSingleLinkRegularFile(sourceStatus),
                      sourceStatus.st_size > 0,
                      trustedFile.identity.matches(sourceStatus, includingSize: true) else {
                    throw TrustedSegmentCopyError.sourceTrustChanged
                }

                let destinationDescriptor = Darwin.openat(
                    destinationDirectoryDescriptor,
                    trustedFile.basename,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
                guard destinationDescriptor >= 0 else {
                    throw TrustedSegmentCopyError.invalidDestination
                }
                var createdStatus = stat()
                guard Darwin.fstat(destinationDescriptor, &createdStatus) == 0,
                      isOwnedSingleLinkRegularFile(createdStatus) else {
                    _ = Darwin.close(destinationDescriptor)
                    throw TrustedSegmentCopyError.invalidDestination
                }
                createdFiles.append(
                    TrustedPrivateSegmentFile(
                        basename: trustedFile.basename,
                        identity: SegmentObjectIdentity(createdStatus)
                    )
                )
                do {
                    guard Darwin.fchmod(destinationDescriptor, mode_t(0o600)) == 0 else {
                        throw TrustedSegmentCopyError.invalidDestination
                    }
                    try copyExactly(
                        sourceDescriptor: sourceDescriptor,
                        destinationDescriptor: destinationDescriptor,
                        byteCount: trustedFile.identity.size,
                        deadline: deadline
                    )
                    guard Darwin.fsync(destinationDescriptor) == 0 else {
                        throw TrustedSegmentCopyError.copyFailed
                    }
                    var copiedStatus = stat()
                    guard Darwin.fstat(destinationDescriptor, &copiedStatus) == 0,
                          isOwnedSingleLinkRegularFile(copiedStatus),
                          copiedStatus.st_size == trustedFile.identity.size else {
                        throw TrustedSegmentCopyError.copyFailed
                    }
                    createdFiles[createdFiles.count - 1] = TrustedPrivateSegmentFile(
                        basename: trustedFile.basename,
                        identity: SegmentObjectIdentity(copiedStatus)
                    )
                } catch {
                    var failedStatus = stat()
                    if Darwin.fstat(destinationDescriptor, &failedStatus) == 0,
                       isOwnedSingleLinkRegularFile(failedStatus),
                       createdFiles[createdFiles.count - 1].identity.matches(
                        failedStatus,
                        includingSize: false
                       ) {
                        createdFiles[createdFiles.count - 1] = TrustedPrivateSegmentFile(
                            basename: trustedFile.basename,
                            identity: SegmentObjectIdentity(failedStatus)
                        )
                    }
                    _ = Darwin.close(destinationDescriptor)
                    throw error
                }
                _ = Darwin.close(destinationDescriptor)

                var finalSourceStatus = stat()
                guard Darwin.fstat(sourceDescriptor, &finalSourceStatus) == 0,
                      isOwnedSingleLinkRegularFile(finalSourceStatus),
                      trustedFile.identity.matches(
                        finalSourceStatus,
                        includingSize: true
                      ) else {
                    throw TrustedSegmentCopyError.sourceTrustChanged
                }
            }

            let copiedSet = TrustedPrivateSegmentSet(
                directoryURL: destinationDirectoryURL,
                directoryIdentity: destinationIdentity,
                files: createdFiles
            )
            guard recheckPrivateCopies(
                copiedSet,
                in: destinationDirectoryDescriptor
            ) else {
                throw TrustedSegmentCopyError.invalidDestination
            }
            return copiedSet
        } catch {
            removePrivateFiles(
                createdFiles,
                from: destinationDirectoryDescriptor
            )
            throw error
        }
    }

    /// Rechecks the exact private inventory, its directory path binding, and
    /// every file identity. Call this immediately before and after a path-based
    /// decoder or merger boundary.
    static func recheckPrivateCopies(
        _ copies: TrustedPrivateSegmentSet,
        in destinationDirectoryDescriptor: Int32
    ) -> Bool {
        guard privateDirectoryMatches(
            copies,
            descriptor: destinationDirectoryDescriptor
        ), directoryEntryNames(descriptor: destinationDirectoryDescriptor)
            == Set(copies.files.map(\.basename)) else {
            return false
        }
        for index in copies.files.indices {
            guard recheckPrivateCopy(
                copies,
                at: index,
                in: destinationDirectoryDescriptor
            ) else { return false }
        }
        return privateDirectoryMatches(
            copies,
            descriptor: destinationDirectoryDescriptor
        )
    }

    /// Reopens the exact URL boundary the decoder will use, as well as the
    /// descriptor-relative basename, and requires both to retain the identity
    /// captured when the verified copy completed.
    static func recheckPrivateCopy(
        _ copies: TrustedPrivateSegmentSet,
        at index: Int,
        in destinationDirectoryDescriptor: Int32
    ) -> Bool {
        guard copies.files.indices.contains(index),
              privateDirectoryMatches(
                copies,
                descriptor: destinationDirectoryDescriptor
              ) else { return false }
        let file = copies.files[index]
        let relativeDescriptor = Darwin.openat(
            destinationDirectoryDescriptor,
            file.basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard relativeDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(relativeDescriptor) }
        var relativeStatus = stat()
        guard Darwin.fstat(relativeDescriptor, &relativeStatus) == 0,
              isOwnedSingleLinkRegularFile(relativeStatus),
              file.identity.matches(relativeStatus, includingSize: true) else {
            return false
        }

        let pathDescriptor = Darwin.open(
            copies.decodingURL(at: index).path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard pathDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(pathDescriptor) }
        var pathStatus = stat()
        return Darwin.fstat(pathDescriptor, &pathStatus) == 0
            && isOwnedSingleLinkRegularFile(pathStatus)
            && file.identity.matches(pathStatus, includingSize: true)
    }

    static func removeVerifiedPrivateCopies(
        _ copies: TrustedPrivateSegmentSet,
        from destinationDirectoryDescriptor: Int32
    ) {
        guard privateDirectoryMatches(
            copies,
            descriptor: destinationDirectoryDescriptor
        ) else { return }
        removePrivateFiles(copies.files, from: destinationDirectoryDescriptor)
    }

    private static func copyExactly(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        byteCount: Int64,
        deadline: ContinuousClock.Instant?
    ) throws {
        guard byteCount > 0 else {
            throw TrustedSegmentCopyError.copyFailed
        }
        var remaining = byteCount
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while remaining > 0 {
            try checkCopyProgress(deadline: deadline)
            let requested = min(buffer.count, Int(remaining))
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, requested)
            }
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead > 0 else {
                throw TrustedSegmentCopyError.copyFailed
            }

            var written = 0
            while written < bytesRead {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        bytesRead - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw TrustedSegmentCopyError.copyFailed
                }
                written += result
            }
            remaining -= Int64(bytesRead)
        }

        var extraByte: UInt8 = 0
        while true {
            let extraRead = Darwin.read(sourceDescriptor, &extraByte, 1)
            if extraRead < 0, errno == EINTR { continue }
            guard extraRead == 0 else {
                throw TrustedSegmentCopyError.sourceTrustChanged
            }
            break
        }
    }

    private static func checkCopyProgress(
        deadline: ContinuousClock.Instant?
    ) throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline {
            throw TrustedSegmentCopyError.copyTimedOut
        }
    }

    private static func privateDirectoryMatches(
        _ copies: TrustedPrivateSegmentSet,
        descriptor: Int32
    ) -> Bool {
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              isDirectory(descriptorStatus),
              copies.directoryIdentity.matches(
                descriptorStatus,
                includingSize: false
              ) else { return false }

        let pathDescriptor = Darwin.open(
            copies.directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard pathDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(pathDescriptor) }
        var pathStatus = stat()
        return Darwin.fstat(pathDescriptor, &pathStatus) == 0
            && copies.directoryIdentity.matches(pathStatus, includingSize: false)
    }

    private static func removePrivateFiles(
        _ files: [TrustedPrivateSegmentFile],
        from destinationDirectoryDescriptor: Int32
    ) {
        for file in files {
            let descriptor = Darwin.openat(
                destinationDirectoryDescriptor,
                file.basename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else { continue }
            var openedStatus = stat()
            var pathStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                  isOwnedSingleLinkRegularFile(openedStatus),
                  file.identity.matches(openedStatus, includingSize: true),
                  Darwin.fstatat(
                    destinationDirectoryDescriptor,
                    file.basename,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  file.identity.matches(pathStatus, includingSize: true) else {
                _ = Darwin.close(descriptor)
                continue
            }
            _ = Darwin.unlinkat(destinationDirectoryDescriptor, file.basename, 0)
            _ = Darwin.close(descriptor)
        }
    }

    private static func openRecordingDirectory(
        recordingID: UUID,
        authority: SegmentStorageAuthority
    ) -> Int32? {
        let rootDescriptor = Darwin.open(
            authority.openedRootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { return nil }
        defer { _ = Darwin.close(rootDescriptor) }

        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0,
              isDirectory(rootStatus),
              authority.rootIdentity.matches(rootStatus, includingSize: false) else {
            return nil
        }

        let segmentsDescriptor = Darwin.openat(
            rootDescriptor,
            "segments",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard segmentsDescriptor >= 0 else { return nil }
        defer { _ = Darwin.close(segmentsDescriptor) }

        var segmentsStatus = stat()
        guard Darwin.fstat(segmentsDescriptor, &segmentsStatus) == 0,
              isDirectory(segmentsStatus) else { return nil }

        let recordingDescriptor = Darwin.openat(
            segmentsDescriptor,
            recordingID.uuidString,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard recordingDescriptor >= 0 else { return nil }
        return recordingDescriptor
    }

    private static func readExactly(
        descriptor: Int32,
        expectedIdentity: SegmentObjectIdentity,
        maximumBytes: Int64
    ) -> Data? {
        guard expectedIdentity.size > 0,
              expectedIdentity.size <= maximumBytes,
              let expectedCount = Int(exactly: expectedIdentity.size) else { return nil }
        var data = Data(count: expectedCount)
        let didReadAll = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return expectedCount == 0 }
            var offset = 0
            while offset < expectedCount {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedCount - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard didReadAll else { return nil }

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              isOwnedSingleLinkRegularFile(finalStatus),
              expectedIdentity.matches(finalStatus, includingSize: true) else { return nil }
        return data
    }

    private static func directoryEntryNames(descriptor: Int32) -> Set<String>? {
        // `dup` shares the directory stream offset, so repeated trust checks
        // would observe an empty inventory after the first scan. Reopen `.` to
        // obtain an independent file description for every exact inventory.
        let inventoryDescriptor = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard inventoryDescriptor >= 0 else { return nil }
        guard let directory = Darwin.fdopendir(inventoryDescriptor) else {
            _ = Darwin.close(inventoryDescriptor)
            return nil
        }
        defer { _ = Darwin.closedir(directory) }

        var names = Set<String>()
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                return errno == 0 ? names : nil
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != ".", name != ".." {
                names.insert(name)
            }
        }
    }

    private static func deterministicSegmentFilename(index: Int) -> String {
        String(format: "segment-%03d.m4a", index)
    }

    private static func isDirectory(_ fileStatus: stat) -> Bool {
        fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isRegularFile(_ fileStatus: stat) -> Bool {
        fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func isOwnedSingleLinkRegularFile(_ fileStatus: stat) -> Bool {
        isRegularFile(fileStatus)
            && fileStatus.st_uid == Darwin.geteuid()
            && fileStatus.st_nlink == 1
    }
}
