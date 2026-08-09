import Foundation
import AVFoundation
import CoreMedia
import os.log

private let audioCaptureLog = Logger(subsystem: "com.cadenza", category: "AudioCapture")

/// Captures system audio via Core Audio process taps and microphone via
/// Core Audio HAL (`AudioDeviceCreateIOProcIDWithBlock` directly on the input
/// device), bypassing `AVAudioEngine`.
///
/// **Why bypass AVAudioEngine for mic?** On macOS 26 with certain device
/// combinations (Continuity iPhone Microphone, virtual conferencing drivers,
/// USB-C dock audio) `AVAudioEngine.inputNode` triggers macOS to build a
/// `CADefaultDeviceAggregate` whose bus 1 channel-layout query fails with
/// `kAudioDeviceUnsupportedFormatError (-10877)` → "input hw format
/// invalid" → engine init `-10868`. The aggregate is malformed at the OS
/// level; retrying or rederiving formats can't recover. Talking to the mic
/// device directly through the HAL skips the aggregate path entirely.
///
/// Pausing the mic IOProc (via `setMicCapture(enabled: false)`) keeps the
/// mic-probe path working — `kAudioDevicePropertyDeviceIsRunningSomewhere`
/// reflects only other apps' usage while we're "paused".
final class AudioCaptureService: @unchecked Sendable {
    private let processTapCapture = ProcessTapSystemAudioCapture()
    private let micCapture = MicrophoneCoreAudioCapture()

    private(set) var isCapturing = false

    var hasActiveCaptureResources: Bool {
        isCapturing
            || processTapCapture.hasActiveResources
            || micCapture.hasActiveResources
    }

    var onSystemAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var onMicrophoneAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var onStreamError: (@Sendable (String) -> Void)?

    // MARK: - Start Capture

    /// Starts and immediately tears down a process tap from an explicit user
    /// action. A successful return means the tap reached `AudioDeviceStart`; it
    /// does not provide a durable or queryable authorization status.
    func prepareSystemAudioCapture() async throws {
        guard !hasActiveCaptureResources else {
            throw ProcessTapCaptureError.operationFailed(
                String(localized: "Stop the current recording before setting up System Audio Recording.")
            )
        }

        // A previous recording may have left its callback installed on this
        // reusable service. Priming must never deliver buffers to an old writer.
        processTapCapture.onSystemAudio = nil
        do {
            try processTapCapture.startCapture()
            processTapCapture.stopCapture()
        } catch {
            processTapCapture.stopCapture()
            throw error
        }
    }

    /// Start capturing audio. Optionally target a specific app by bundle ID.
    func startCapture(
        targetBundleID: String? = nil,
        captureMicrophone: Bool = true,
        microphoneDeviceID: String? = nil
    ) async throws {
        guard !isCapturing else { return }

        processTapCapture.onSystemAudio = { [weak self] buffer in
            self?.onSystemAudio?(buffer)
        }
        micCapture.onMicrophoneAudio = { [weak self] buffer in
            self?.onMicrophoneAudio?(buffer)
        }

        do {
            try processTapCapture.startCapture(targetBundleID: targetBundleID)
            self.isCapturing = true

            if captureMicrophone {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                if micStatus == .authorized {
                    try micCapture.startCapture(deviceUID: microphoneDeviceID)
                } else {
                    audioCaptureLog.notice(
                        "Mic capture skipped: permission status=\(micStatus.rawValue, privacy: .public)"
                    )
                }
            }
        } catch {
            // Specific awareness for the OS-level aggregate corruption we
            // hit on the mic path (fixed in 7fc20d7 by going around
            // AVAudioEngine). If the SAME class of bug ever surfaces in the
            // process-tap aggregate or the mic HAL path, leave a clear
            // breadcrumb in the unified log so future debugging connects
            // to MEMORY.md §"OS-level Audio Traps".
            if Self.containsAggregateCorruptionStatus(error) {
                audioCaptureLog.error("""
                    Audio capture failed with the OS-level aggregate-corruption \
                    signature (-10877). This is the same bug class that the \
                    AVAudioEngine→HAL migration fixed for mic; if it appears \
                    here it means it also reached the process-tap or HAL path. \
                    See MEMORY.md "OS-level Audio Traps". \
                    error=\(String(describing: error), privacy: .public)
                    """)
            } else {
                audioCaptureLog.error(
                    "startCapture failed: \(String(describing: error), privacy: .public)"
                )
            }
            micCapture.stopCapture()
            processTapCapture.stopCapture()
            self.isCapturing = false
            throw error
        }
    }

    /// Detect the -10877 (`kAudioDeviceUnsupportedFormatError`) OSStatus
    /// inside a thrown audio-capture error. Used to attach a high-signal
    /// breadcrumb when the OS-level aggregate-corruption signature recurs.
    private static func containsAggregateCorruptionStatus(_ error: Error) -> Bool {
        if let micErr = error as? MicrophoneCoreAudioError,
           case .osStatus(_, let status) = micErr, status == -10877 {
            return true
        }
        if let tapErr = error as? ProcessTapCaptureError,
           case .osStatus(_, let status) = tapErr, status == -10877 {
            return true
        }
        return false
    }

    // MARK: - Mic Probe (pause/resume)

    /// Pause/resume mic capture. Stopping the device IOProc releases the
    /// hardware so other apps' usage shows up cleanly in CoreAudio's
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` without our recording
    /// confusing the signal.
    func setMicCapture(enabled: Bool) {
        if enabled {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            guard micStatus == .authorized else {
                audioCaptureLog.notice(
                    "Mic resume skipped: permission status=\(micStatus.rawValue, privacy: .public)"
                )
                return
            }
        }
        micCapture.setActive(enabled)
    }

    // MARK: - Stop Capture

    func stopCapture() async throws {
        if micCapture.hasActiveResources {
            micCapture.stopCapture()
            audioCaptureLog.info("Mic capture stopped")
        }

        if processTapCapture.hasActiveResources {
            processTapCapture.stopCapture()
            audioCaptureLog.info("Core Audio process tap stopped")
        }

        self.isCapturing = false
    }

    /// Force-reset all capture state. Process-tap and mic resources are
    /// destroyed synchronously.
    func forceReset() {
        audioCaptureLog.notice("forceReset: forcibly clearing state")
        micCapture.forceReset()
        processTapCapture.forceReset()
        isCapturing = false
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {
    case microphoneNotAvailable

    var errorDescription: String? {
        switch self {
        case .microphoneNotAvailable:
            return String(
                localized: "Cadenza couldn't start the microphone. Check the selected microphone and Microphone access in System Settings, then try again."
            )
        }
    }
}
