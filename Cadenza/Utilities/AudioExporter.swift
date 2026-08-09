import AVFoundation
import Foundation
import Synchronization

/// Shared AVAssetReader/Writer pipeline for audio format conversion.
/// Replaces deprecated AVAssetExportSession across the codebase.
enum AudioExporter {
    enum WriterSetupFailure: CaseIterable, Sendable {
        case cannotAddInput
        case cannotStartWriting
    }

    struct CancellationSnapshot: Equatable, Sendable {
        let readerStatus: Int
        let writerStatus: Int
    }

    struct TestHooks: Sendable {
        let writerSetupFailure: WriterSetupFailure?
        let onWriterCreated: @Sendable (URL) -> Void
        let beforeFirstDrain: @Sendable () -> Void
        let onPumpTerminal: @Sendable () -> Void
        let onCancel: @Sendable (CancellationSnapshot) -> Void
        let onDeinit: @Sendable () -> Void

        init(
            writerSetupFailure: WriterSetupFailure? = nil,
            onWriterCreated: @escaping @Sendable (URL) -> Void = { _ in },
            beforeFirstDrain: @escaping @Sendable () -> Void = {},
            onPumpTerminal: @escaping @Sendable () -> Void = {},
            onCancel: @escaping @Sendable (CancellationSnapshot) -> Void = { _ in },
            onDeinit: @escaping @Sendable () -> Void = {}
        ) {
            self.writerSetupFailure = writerSetupFailure
            self.onWriterCreated = onWriterCreated
            self.beforeFirstDrain = beforeFirstDrain
            self.onPumpTerminal = onPumpTerminal
            self.onCancel = onCancel
            self.onDeinit = onDeinit
        }

        static let none = TestHooks()
    }

    struct OutputSettings: Sendable {
        let channels: Int
        let sampleRate: Double
        let bitRate: Int

        /// Stereo 44.1 kHz 128 kbps — preserves quality for user imports.
        static let importQuality = OutputSettings(channels: 2, sampleRate: 44100, bitRate: 128_000)
        /// Mono 44.1 kHz 128 kbps — fair baseline for test/diagnostic clips.
        static let clipQuality = OutputSettings(channels: 1, sampleRate: 44100, bitRate: 128_000)
        /// Mono 24 kHz 48 kbps — aggressive compression for storage-optimized recordings.
        static let compressed = OutputSettings(channels: 1, sampleRate: 24000, bitRate: 48_000)
    }

    /// Export (optionally clipped) audio to M4A using AVAssetReader/Writer.
    ///
    /// Resilient to mid-track decode failures: some externally-produced files
    /// (notably Teams meeting-recording MP4s) contain an AAC frame that
    /// AVFoundation's decoder rejects (`-11800` / OSStatus `-50`) partway
    /// through. The reader then fails and `copyNextSampleBuffer()` returns nil —
    /// which must NOT be treated as a clean end-of-stream, or the output is
    /// silently truncated. On such a failure, the pump skips a small gap past
    /// the bad frame and resumes with a fresh reader.
    @MainActor
    static func exportToM4A(
        asset: AVURLAsset,
        track: AVAssetTrack,
        outputURL: URL,
        settings: OutputSettings,
        timeRange: CMTimeRange? = nil,
        testHooks: TestHooks = .none
    ) async throws {
        try Task.checkCancellation()

        let sessionStart = timeRange?.start ?? .zero
        let overallEnd: CMTime
        if let timeRange {
            overallEnd = CMTimeAdd(timeRange.start, timeRange.duration)
        } else {
            overallEnd = try await asset.load(.duration)
        }

        try Task.checkCancellation()
        let pump = try await AudioExportPump.make(
            asset: asset,
            trackID: track.trackID,
            outputURL: outputURL,
            settings: settings,
            sessionStart: sessionStart,
            overallEnd: overallEnd,
            clipped: timeRange != nil,
            testHooks: testHooks
        )
        try await pump.run()
    }
}

/// Owns every non-Sendable AVFoundation reader/writer object behind one mutex.
/// The AVAssetWriter callback therefore captures only this Sendable handle and
/// the Sendable completion closures. Long-running sample work remains on the
/// dedicated utility queue, never on MainActor.
private final class AudioExportPump: Sendable {
    private enum Phase {
        case idle
        case pumping
        case pumped
        case finishing
        case finished
        case failed
        case cancelled
    }

    private struct State {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let writer: AVAssetWriter
        let writerInput: AVAssetWriterInput
        let outputURL: URL
        let sessionStart: CMTime
        let overallEnd: CMTime
        let clipped: Bool
        let gap = CMTime(seconds: 0.2, preferredTimescale: 600)

        var reader: AVAssetReader
        var readerOutput: AVAssetReaderTrackOutput
        var lastEnd: CMTime
        var resumeFrom: CMTime
        var attempts = 0
        var skips = 0
        var phase = Phase.idle

        mutating func tryResume() -> Bool {
            let base = CMTimeMaximum(lastEnd, resumeFrom)
            attempts += 1
            let skip = CMTimeMultiply(gap, multiplier: Int32(min(attempts, 50)))
            let next = CMTimeAdd(base, skip)
            guard attempts <= 300, CMTimeCompare(next, overallEnd) < 0,
                  let resumed = Self.makeReader(
                    asset: asset,
                    track: track,
                    from: next,
                    sessionStart: sessionStart,
                    overallEnd: overallEnd,
                    clipped: clipped
                  ) else {
                return false
            }

            reader = resumed.reader
            readerOutput = resumed.output
            resumeFrom = next
            skips += 1
            return true
        }

        static func makeReader(
            asset: AVURLAsset,
            track: AVAssetTrack,
            from: CMTime,
            sessionStart: CMTime,
            overallEnd: CMTime,
            clipped: Bool
        ) -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput)? {
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            if clipped || CMTimeCompare(from, sessionStart) > 0 {
                reader.timeRange = CMTimeRange(
                    start: from,
                    duration: CMTimeSubtract(overallEnd, from)
                )
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            return (reader, output)
        }
    }

    private let queue = DispatchQueue(label: "cadenza.audio-export", qos: .utility)
    private let state: Mutex<State>
    private let testHooks: AudioExporter.TestHooks

    static func make(
        asset: AVURLAsset,
        trackID: CMPersistentTrackID,
        outputURL: URL,
        settings: AudioExporter.OutputSettings,
        sessionStart: CMTime,
        overallEnd: CMTime,
        clipped: Bool,
        testHooks: AudioExporter.TestHooks
    ) async throws -> AudioExportPump {
        guard let track = try await asset.loadTrack(withTrackID: trackID) else {
            throw NSError(domain: "AudioExporter", code: -3)
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard let first = State.makeReader(
            asset: asset,
            track: track,
            from: sessionStart,
            sessionStart: sessionStart,
            overallEnd: overallEnd,
            clipped: clipped
        ) else {
            throw NSError(domain: "AudioExporter", code: -3)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            first.reader.cancelReading()
            throw error
        }
        testHooks.onWriterCreated(outputURL)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: settings.channels,
            AVSampleRateKey: settings.sampleRate,
            AVEncoderBitRateKey: settings.bitRate,
        ])
        guard testHooks.writerSetupFailure != .cannotAddInput,
              writer.canAdd(writerInput) else {
            first.reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw NSError(domain: "AudioExporter", code: -4)
        }
        writer.add(writerInput)
        guard testHooks.writerSetupFailure != .cannotStartWriting,
              writer.startWriting() else {
            let error = writer.error ?? NSError(domain: "AudioExporter", code: -5)
            first.reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        writer.startSession(atSourceTime: sessionStart)

        return AudioExportPump(state: State(
            asset: asset,
            track: track,
            writer: writer,
            writerInput: writerInput,
            outputURL: outputURL,
            sessionStart: sessionStart,
            overallEnd: overallEnd,
            clipped: clipped,
            reader: first.reader,
            readerOutput: first.output,
            lastEnd: sessionStart,
            resumeFrom: sessionStart
        ), testHooks: testHooks)
    }

    private init(
        state: sending State,
        testHooks: AudioExporter.TestHooks
    ) {
        self.state = Mutex(state)
        self.testHooks = testHooks
    }

    deinit {
        testHooks.onDeinit()
    }

    func run() async throws {
        try await CancellableCallbackOperation.run { complete, isActive in
            self.startPumping(complete: complete, isActive: isActive)
        } cancel: {
            self.cancel()
        }

        try await CancellableCallbackOperation.run { complete, isActive in
            self.startFinishing(complete: complete, isActive: isActive)
        } cancel: {
            self.cancel()
        }
    }

    func startPumping(
        complete: @escaping CancellableCallbackOperation.Completion,
        isActive: @escaping CancellableCallbackOperation.IsActive
    ) {
        let beforeFirstDrain = testHooks.beforeFirstDrain
        let onPumpTerminal = testHooks.onPumpTerminal
        state.withLock { state in
            guard state.phase == .idle else { return }
            state.phase = .pumping
            state.writerInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                beforeFirstDrain()
                guard let self, isActive() else { return }
                let result = self.drain(isActive: isActive)
                if let result {
                    onPumpTerminal()
                    _ = complete(result)
                }
            }
        }
    }

    func startFinishing(
        complete: @escaping CancellableCallbackOperation.Completion,
        isActive: @escaping CancellableCallbackOperation.IsActive
    ) {
        let immediateError = state.withLock { state -> Error? in
            guard state.phase == .pumped else {
                return NSError(domain: "AudioExporter", code: -6)
            }
            state.phase = .finishing
            state.writer.finishWriting { [weak self] in
                guard let self, isActive() else { return }
                let result = self.finishResult()
                _ = complete(result)
            }
            return nil
        }

        if let immediateError {
            _ = complete(.failure(immediateError))
        }
    }

    func cancel() {
        let cancellation = state.withLock {
            state -> (outputURL: URL, snapshot: AudioExporter.CancellationSnapshot)? in
            guard state.phase != .cancelled, state.phase != .finished else { return nil }
            state.reader.cancelReading()
            state.writer.cancelWriting()
            state.phase = .cancelled
            return (
                state.outputURL,
                AudioExporter.CancellationSnapshot(
                    readerStatus: state.reader.status.rawValue,
                    writerStatus: state.writer.status.rawValue
                )
            )
        }
        guard let cancellation else { return }

        try? FileManager.default.removeItem(at: cancellation.outputURL)
        testHooks.onCancel(cancellation.snapshot)
    }

    private func drain(
        isActive: CancellableCallbackOperation.IsActive
    ) -> Result<Void, Error>? {
        state.withLock { state in
            guard state.phase == .pumping else { return nil }

            while state.writerInput.isReadyForMoreMediaData, isActive() {
                if state.reader.status == .failed {
                    if state.tryResume() { continue }
                    return finishPumping(&state)
                }

                if let buffer = state.readerOutput.copyNextSampleBuffer() {
                    let end = CMTimeAdd(
                        CMSampleBufferGetPresentationTimeStamp(buffer),
                        CMSampleBufferGetDuration(buffer)
                    )
                    if end.isValid, CMTimeCompare(end, state.lastEnd) > 0 {
                        state.lastEnd = end
                    }
                    guard state.writerInput.append(buffer) else {
                        let error = state.writer.error
                            ?? NSError(domain: "AudioExporter", code: -1)
                        state.phase = .failed
                        return .failure(error)
                    }
                } else if state.reader.status == .failed {
                    if state.tryResume() { continue }
                    return finishPumping(&state)
                } else {
                    return finishPumping(&state)
                }
            }
            return nil
        }
    }

    private func finishPumping(_ state: inout State) -> Result<Void, Error> {
        state.writerInput.markAsFinished()
        state.phase = .pumped
        return .success(())
    }

    private func finishResult() -> Result<Void, Error> {
        let snapshot = state.withLock { state -> (Result<Void, Error>, Int) in
            guard state.phase == .finishing else {
                return (.failure(NSError(domain: "AudioExporter", code: -7)), state.skips)
            }
            guard state.writer.status == .completed else {
                state.phase = .failed
                return (
                    .failure(state.writer.error ?? NSError(domain: "AudioExporter", code: -2)),
                    state.skips
                )
            }
            state.phase = .finished
            return (.success(()), state.skips)
        }

        if snapshot.1 > 0 {
            NSLog(
                "[AudioExporter] recovered audio across %d decode gap(s); source had frame(s) AVFoundation could not decode",
                snapshot.1
            )
        }
        return snapshot.0
    }
}
