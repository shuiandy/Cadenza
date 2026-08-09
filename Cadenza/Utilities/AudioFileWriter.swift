@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os

/// Writes audio sample buffers to an .m4a file using AVAssetWriter.
/// Supports two independent audio inputs (system + microphone) with separate timestamp tracking.
/// Thread-safe via internal serial queue. Call from any thread.
final class AudioFileWriter: @unchecked Sendable {
    private var assetWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let queue = DispatchQueue(label: "com.shuiandy.Cadenza.fileWriter")

    private(set) var isWriting = false
    private(set) var outputURL: URL?

    /// Called once when the writer enters a failed state during append.
    /// Fires on the writer's internal serial queue — do not block.
    var onWriterFailure: (@Sendable (String) -> Void)?

    // MARK: - Start Writing

    func startWriting(to url: URL, sampleRate: Double = 48000, channels: UInt32 = 1) throws {
        try queue.sync {
            guard !isWriting else { return }

            try? FileManager.default.removeItem(at: url)

            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128000
            ]

            let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            sysInput.expectsMediaDataInRealTime = true

            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            micInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(sysInput), writer.canAdd(micInput) else {
                throw AudioFileWriterError.cannotAddInput
            }

            writer.add(sysInput)
            writer.add(micInput)

            guard writer.startWriting() else {
                throw AudioFileWriterError.startWritingFailed(writer.error?.localizedDescription ?? "unknown")
            }

            self.assetWriter = writer
            self.systemAudioInput = sysInput
            self.micAudioInput = micInput
            self.outputURL = url
            self.sessionStarted = false
            self.writerFailureLogged = false
            self.isWriting = true
        }
    }

    // MARK: - Append System Audio (call from any thread)

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [weak self] in
            guard let self else { return }
            self.startSessionIfNeeded(with: buffer)
            self.appendBuffer(buffer, to: self.systemAudioInput)
        }
    }

    // MARK: - Append Microphone Audio (call from any thread)

    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [weak self] in
            guard let self else { return }
            self.startSessionIfNeeded(with: buffer)
            self.appendBuffer(buffer, to: self.micAudioInput)
        }
    }

    // MARK: - Legacy single-stream append (for backward compatibility)

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        appendSystemAudio(sampleBuffer)
    }

    // MARK: - Stop Writing

    func stopWriting() async -> URL? {
        // Atomically capture state and mark as not-writing to prevent double-stop.
        // rotateSegment() and stopWriting() can race on the same writer — setting
        // isWriting=false here ensures only one caller proceeds to finishWriting.
        let (writer, url, status) = queue.sync { () -> (AVAssetWriter?, URL?, AVAssetWriter.Status) in
            guard isWriting, let w = assetWriter else { return (nil, nil, .unknown) }
            isWriting = false
            systemAudioInput?.markAsFinished()
            micAudioInput?.markAsFinished()
            return (w, outputURL, w.status)
        }

        guard let writer else { return nil }

        // finishWriting MUST only be called when status == .writing.
        // Apple docs: "Do not call this method when the status is not writing."
        // If status is .failed/.cancelled, the completion handler is never called → hang.
        if status == .writing {
            // Race finishWriting against a 10-second timeout to prevent permanent hangs.
            let didFinish = OSAllocatedUnfairLock(initialState: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    if didFinish.withLock({ let old = $0; $0 = true; return !old }) {
                        continuation.resume()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    if didFinish.withLock({ let old = $0; $0 = true; return !old }) {
                        NSLog("[Cadenza] AudioFileWriter.stopWriting: finishWriting timed out after 10s")
                        continuation.resume()
                    }
                }
            }

            if writer.status != .completed {
                NSLog("[Cadenza] AudioFileWriter.finishWriting ended with status=%d error=%@",
                      writer.status.rawValue, writer.error?.localizedDescription ?? "nil")
            }
        } else {
            NSLog("[Cadenza] AudioFileWriter.stopWriting: writer status=%d, skipping finishWriting",
                  status.rawValue)
        }

        queue.sync {
            assetWriter = nil
            systemAudioInput = nil
            micAudioInput = nil
            sessionStarted = false
        }

        return url
    }

    /// Force-reset all state without waiting for AVAssetWriter to finish.
    /// Called when the graceful stopWriting() hangs past its timeout.
    /// Marks inputs as finished and drops references — does NOT cancel the writer,
    /// so the partially-written file remains valid on disk.
    func forceReset() {
        queue.sync {
            NSLog("[Cadenza] AudioFileWriter.forceReset: forcibly clearing writer state (preserving file)")
            systemAudioInput?.markAsFinished()
            micAudioInput?.markAsFinished()
            // Drop references without cancelWriting() — the file stays valid on disk.
            // AVAssetWriter will finalize in the background when deallocated.
            assetWriter = nil
            systemAudioInput = nil
            micAudioInput = nil
            isWriting = false
            sessionStarted = false
        }
    }

    // MARK: - Private

    private func startSessionIfNeeded(with sampleBuffer: CMSampleBuffer) {
        guard !sessionStarted, let writer = assetWriter else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: timestamp)
        sessionStarted = true
    }

    private var writerFailureLogged = false

    private func appendBuffer(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard isWriting,
              let writer = assetWriter,
              let input else {
            return
        }
        if writer.status != .writing {
            if !writerFailureLogged {
                writerFailureLogged = true
                let errorDesc = writer.error?.localizedDescription ?? "unknown"
                NSLog("[Cadenza] AudioFileWriter: writer failed (%@), subsequent buffers will be dropped", errorDesc)
                onWriterFailure?("AudioFileWriter failed: \(errorDesc)")
            }
            return
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}

enum AudioFileWriterError: Error, LocalizedError {
    case cannotAddInput
    case startWritingFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Cannot add audio input to asset writer"
        case .startWritingFailed(let reason):
            return "AVAssetWriter.startWriting() failed: \(reason)"
        }
    }
}
