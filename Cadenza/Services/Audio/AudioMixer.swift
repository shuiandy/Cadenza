import AVFoundation
import CoreMedia

/// Thread-safe pause flag readable from background audio callbacks.
fileprivate final class PauseFlag: @unchecked Sendable {
    private var _value = false
    var isPaused: Bool {
        get { _value }
        set { _value = newValue }
    }
}

/// Throttles audio level calculation to every Nth buffer (~8Hz instead of ~100Hz).
private final class AudioLevelSampler: @unchecked Sendable {
    enum Reading {
        case skipped          // throttled out — no information
        case level(Float)     // normalized level
        case unknownFormat    // buffer format unsupported — treat as audible
    }

    private var counter = 0
    private let interval = 12  // calculate every 12th buffer

    func read(from buffer: CMSampleBuffer) -> Reading {
        counter += 1
        guard counter >= interval else { return .skipped }
        counter = 0
        guard let level = AudioLevelMeter.normalizedLevel(from: buffer) else {
            return .unknownFormat
        }
        return .level(level)
    }
}

/// Manages the combined audio capture pipeline:
/// - System audio (from Core Audio process taps)
/// - Microphone audio (from AVAudioEngine)
/// - Writes mixed audio to file
/// - Provides converted buffers for real-time transcription
@Observable @MainActor
final class AudioMixer {
    private let captureService = AudioCaptureService()
    private let segmentedWriter = SegmentedAudioFileWriter()

    private(set) var isRecording = false
    /// When true, audio capture continues but buffers are not written to disk.
    /// Accessed via pauseFlag for thread-safe reads from background audio callbacks.
    fileprivate let pauseFlag = PauseFlag()
    var isPaused: Bool {
        get { pauseFlag.isPaused }
        set { pauseFlag.isPaused = newValue }
    }
    /// Written ~8×/sec from the capture callback. No SwiftUI view observes it
    /// directly — RecordingEngine's 0.25s timer reads it and republishes a
    /// throttled `audioLevel`. Marked `@ObservationIgnored` so the per-buffer
    /// write does NOT invalidate views during recording (the RenderBox-sensitive
    /// window — see ARCHITECTURE.md §8.1.2).
    @ObservationIgnored private(set) var currentAudioLevel: Float = 0
    private(set) var recordingStartTime: Date?
    private(set) var outputFileURL: URL?

    /// Sustained-silence tracking across both capture paths (system + mic).
    /// Fed from background callbacks; read by RecordingEngine's watchdog tick.
    private let silenceTracker = SilenceTracker()

    var sustainedSilenceDuration: TimeInterval {
        silenceTracker.silenceDuration
    }

    func resetSilenceTracking() {
        silenceTracker.reset()
    }

    /// Prime the Core Audio tap from a user-initiated UI action without starting
    /// a recording or creating a segmented writer.
    func prepareSystemAudioCapture() async throws {
        guard !isRecording else {
            throw ProcessTapCaptureError.operationFailed(
                String(localized: "Stop the current recording before setting up System Audio Recording.")
            )
        }
        try await captureService.prepareSystemAudioCapture()
    }

    /// Optional callback for forwarding converted audio data (24kHz mono PCM16)
    /// to a real-time transcription service. Set before calling startRecording().
    var onTranscriptionAudio: ((@Sendable (Data) -> Void))?

    /// Optional callback for reporting stream errors to the caller.
    var onStreamError: ((@Sendable (String) -> Void))?

    /// The segments directory for the current recording (set during startRecording).
    private(set) var currentSegmentsDirectory: URL?
    /// The recording ID associated with the current recording session.
    private(set) var currentRecordingID: UUID?

    // MARK: - Start Recording

    func startRecording(
        recordingID: UUID,
        targetBundleID: String? = nil,
        captureMicrophone: Bool = true,
        outputURL: URL? = nil
    ) async throws {
        guard !isRecording else {
            throw AudioMixerError.alreadyRecording
        }

        pauseFlag.isPaused = false
        silenceTracker.reset()
        let url = outputURL ?? defaultOutputURL()
        outputFileURL = url

        // Create segments directory
        let segmentsDir = segmentsDirectory(for: recordingID)
        currentSegmentsDirectory = segmentsDir
        currentRecordingID = recordingID
        NSLog("[Cadenza] AudioMixer.startRecording -> %@ (segments: %@)", url.path, segmentsDir.path)

        // Set up segmented file writer — propagate failures to onStreamError
        segmentedWriter.onWriterFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.onStreamError?(message)
            }
        }
        try segmentedWriter.startWriting(segmentsDir: segmentsDir, recordingID: recordingID)

        // Capture local references for the closures
        let writer = segmentedWriter
        // Only push audio level to MainActor every Nth buffer to avoid flooding
        let levelSampler = AudioLevelSampler()
        let micLevelSampler = AudioLevelSampler()
        let tracker = silenceTracker

        // Capture the transcription callback for use in the closure
        let transcriptionCallback = onTranscriptionAudio
        let streamErrorCallback = onStreamError

        // Capture pause flag for background callback access
        let pause = pauseFlag

        // System audio callback (runs on background DispatchQueue)
        captureService.onSystemAudio = { [weak self] buffer in
            guard !pause.isPaused else { return }
            writer.appendSystemAudio(buffer)

            switch levelSampler.read(from: buffer) {
            case .skipped:
                break
            case .level(let level):
                tracker.record(level: level)
                Task { @MainActor [weak self] in
                    self?.currentAudioLevel = level
                }
            case .unknownFormat:
                tracker.record(level: nil)
            }

            // Forward converted audio for real-time transcription
            if let callback = transcriptionCallback {
                if let pcmBuffer = AudioConverter.convert(sampleBuffer: buffer, to: AudioConverter.transcriptionFormat),
                   let data = AudioConverter.pcmBufferToData(pcmBuffer) {
                    callback(data)
                }
            }
        }

        // Microphone audio callback — writes to its own separate track.
        captureService.onMicrophoneAudio = { buffer in
            guard !pause.isPaused else { return }
            writer.appendMicrophoneAudio(buffer)

            switch micLevelSampler.read(from: buffer) {
            case .skipped:
                break
            case .level(let level):
                tracker.record(level: level)
            case .unknownFormat:
                tracker.record(level: nil)
            }
        }

        // Stream error callback — log and track for diagnostics.
        captureService.onStreamError = { errorMessage in
            NSLog("[Cadenza] AudioMixer: stream error received: %@", errorMessage)
            streamErrorCallback?(errorMessage)
        }

        // Start capture — if this fails, clean up the writer we already started.
        do {
            let micDeviceID = UserDefaults.standard.string(forKey: "selectedMicrophoneID")
            NSLog("[Cadenza] AudioMixer: starting capture (mic=%@, deviceID=%@)",
                  captureMicrophone ? "ON" : "OFF",
                  micDeviceID ?? "system default")
            try await captureService.startCapture(
                targetBundleID: targetBundleID,
                captureMicrophone: captureMicrophone,
                microphoneDeviceID: micDeviceID
            )
        } catch {
            NSLog("[Cadenza] AudioMixer: startCapture failed, cleaning up writer: %@", error.localizedDescription)
            segmentedWriter.forceReset()
            outputFileURL = nil
            currentSegmentsDirectory = nil
            currentRecordingID = nil
            throw error
        }

        recordingStartTime = Date()
        isRecording = true
    }

    // MARK: - Mic Probe

    func setMicCapture(enabled: Bool) {
        captureService.setMicCapture(enabled: enabled)
    }

    // MARK: - Stop Recording

    /// Result of Phase 1 (stop capture + writers, before merge).
    struct StopPhase1Result {
        let segmentURLs: [URL]
        let outputURL: URL?
        let segmentsDirectory: URL?
    }

    /// Phase 1: Stops capture and writers without merging. Fast (<20s).
    /// Synchronously captures references and clears observable state so the UI
    /// sees idle immediately. Returns closures + data needed to finish stopping
    /// audio capture and writers off the MainActor.
    struct PendingStop: Sendable {
        let capture: AudioCaptureService
        let writer: SegmentedAudioFileWriter
        let outputURL: URL?
        let segmentsDirectory: URL?
    }

    func beginStop() -> PendingStop? {
        guard isRecording else { return nil }

        let pending = PendingStop(
            capture: captureService,
            writer: segmentedWriter,
            outputURL: outputFileURL,
            segmentsDirectory: currentSegmentsDirectory
        )

        // Clear observable state synchronously so UI updates immediately
        // Note: pauseFlag is NOT reset here — it stays true until finishStop()
        // completes, so no stray buffers get written during async shutdown.
        isRecording = false
        recordingStartTime = nil
        currentAudioLevel = 0
        currentSegmentsDirectory = nil
        currentRecordingID = nil

        return pending
    }

    /// Run the actual I/O off the MainActor.
    static func finishStop(_ pending: PendingStop) async -> StopPhase1Result {
        try? await pending.capture.stopCapture()
        let segmentURLs = await pending.writer.stopWriting()
        NSLog("[Cadenza] AudioMixer.finishStop -> %d segments", segmentURLs.count)
        return StopPhase1Result(
            segmentURLs: segmentURLs,
            outputURL: pending.outputURL,
            segmentsDirectory: pending.segmentsDirectory
        )
    }

    /// Force-reset all state without waiting for graceful finalization.
    /// Called when the normal stop path hangs past its timeout.
    func forceReset() {
        NSLog("[Cadenza] AudioMixer.forceReset: forcibly clearing capture state")
        captureService.forceReset()
        segmentedWriter.forceReset()
        isRecording = false
        recordingStartTime = nil
        currentAudioLevel = 0
        currentSegmentsDirectory = nil
        currentRecordingID = nil
    }

    /// Tear down only the capture path if it's still active. Used on app quit to
    /// make sure we don't leave process-tap resources alive.
    /// Does NOT touch the segmented writer — if we're idle, the writer is already
    /// inert; if we're recording, the regular shutdown path handles it.
    func tearDownCaptureIfActive() async {
        guard captureService.hasActiveCaptureResources else { return }
        NSLog("[Cadenza] AudioMixer.tearDownCaptureIfActive: tearing down stale capture resources")
        do {
            try await captureService.stopCapture()
        } catch {
            NSLog("[Cadenza] tearDownCaptureIfActive: stopCapture failed, falling back to forceReset: %@", error.localizedDescription)
            captureService.forceReset()
        }
    }

    /// True if the capture service still has active capture resources. Used by
    /// the app delegate to decide whether termination needs async teardown.
    var isCaptureActive: Bool {
        captureService.hasActiveCaptureResources
    }

    // MARK: - Helpers

    private func defaultOutputURL() -> URL {
        let recordingsDir = StorageLocationManager.recordingsDirectory
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "recording_\(formatter.string(from: Date())).m4a"

        return recordingsDir.appendingPathComponent(filename)
    }

    private func segmentsDirectory(for recordingID: UUID) -> URL {
        StorageLocationManager.segmentsDirectory(for: recordingID)
    }
}

enum AudioMixerError: Error, LocalizedError {
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return String(localized: "Recording in Progress")
        }
    }
}
