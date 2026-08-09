import CoreAudio
import CoreAudioTypes
import CoreMedia
import Foundation
import os.log

private let micCaptureLog = Logger(subsystem: "com.cadenza", category: "AudioCapture")

/// Captures microphone audio through the Core Audio HAL directly, bypassing
/// `AVAudioEngine`.
///
/// **Why not AVAudioEngine?** On macOS 26 with certain device combinations
/// (Continuity iPhone Microphone + virtual conferencing audio drivers + USB-C
/// dock audio outputs), the automatic `CADefaultDeviceAggregate` that
/// `AVAudioEngine.inputNode` triggers fails the channel-layout query on
/// bus 1 with `kAudioDeviceUnsupportedFormatError (-10877)`, producing
/// "Error: input hw format invalid" and downstream `-10868`
/// `kAudioUnitErr_FormatNotSupported`. The aggregate is malformed at the
/// macOS level — no amount of retry or format-derivation in user code
/// recovers from it. Talking to the device directly through
/// `AudioDeviceCreateIOProcIDWithBlock` sidesteps the aggregate entirely.
///
/// Mirrors `ProcessTapSystemAudioCapture`'s architecture: a single IOProc
/// registered on the target device, audio buffers wrapped into
/// `CMSampleBuffer` and published to `onMicrophoneAudio` from a utility
/// dispatch queue.
final class MicrophoneCoreAudioCapture {
    private var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var streamFormat = AudioStreamBasicDescription()
    private var formatDescription: CMAudioFormatDescription?
    private(set) var isCapturing = false
    /// Tracks whether the IOProc is currently in the started (running) state,
    /// so `setActive` is idempotent and we don't log spurious `AudioDeviceStop`
    /// failures for double-stops (kAudioHardwareNotRunningError) or
    /// double-starts.
    private var isIOProcActive = false
    private let callbackQueue = DispatchQueue(
        label: "com.shuiandy.Cadenza.micCoreAudio",
        qos: .userInitiated
    )

    var onMicrophoneAudio: (@Sendable (CMSampleBuffer) -> Void)?

    var hasActiveResources: Bool {
        isCapturing
            || deviceID != AudioDeviceID(kAudioObjectUnknown)
            || ioProcID != nil
    }

    // MARK: - Start / Stop

    func startCapture(deviceUID: String? = nil) throws {
        guard !isCapturing else { return }

        let resolvedDeviceID = try resolveDeviceID(uid: deviceUID)
        let format = try readStreamFormat(deviceID: resolvedDeviceID)
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw MicrophoneCoreAudioError.invalidFormat(
                "sampleRate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame)"
            )
        }
        // Reject non-interleaved multi-channel input. With `kAudioFormatFlagIsNonInterleaved`
        // and `mChannelsPerFrame > 1`, the IOProc delivers one `AudioBuffer`
        // per channel (`mNumberBuffers > 1`). `copyAudioPacket` below only
        // copies `mBuffers[0]`, which would yield CMSampleBuffers that claim
        // N channels but only carry channel 0 — corrupt audio downstream.
        // Mono devices (single-buffer) are unaffected regardless of the flag.
        // If someone needs stereo non-interleaved later, extend the IOProc to
        // interleave channels before wrapping.
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if isNonInterleaved && format.mChannelsPerFrame > 1 {
            throw MicrophoneCoreAudioError.invalidFormat(
                "non-interleaved multi-channel input is unsupported (channels=\(format.mChannelsPerFrame))"
            )
        }
        let fmtDesc = try makeFormatDescription(for: format)

        let audioHandler = onMicrophoneAudio
        let queue = callbackQueue
        let ioBlock: AudioDeviceIOBlock = { [format, fmtDesc, audioHandler, queue] _, inputData, inputTime, _, _ in
            guard let packet = Self.copyAudioPacket(
                from: inputData,
                inputTime: inputTime,
                format: format
            ) else { return }
            queue.async {
                guard let sampleBuffer = Self.makeSampleBuffer(
                    from: packet,
                    formatDescription: fmtDesc
                ) else { return }
                audioHandler?(sampleBuffer)
            }
        }

        var newProcID: AudioDeviceIOProcID?
        try checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, resolvedDeviceID, nil, ioBlock),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        guard let newProcID else {
            throw MicrophoneCoreAudioError.operationFailed(
                "AudioDeviceCreateIOProcIDWithBlock returned nil"
            )
        }

        do {
            try checkOSStatus(
                AudioDeviceStart(resolvedDeviceID, newProcID),
                operation: "AudioDeviceStart"
            )
        } catch {
            // Roll back the IOProc registration on Start failure.
            _ = AudioDeviceDestroyIOProcID(resolvedDeviceID, newProcID)
            throw error
        }

        deviceID = resolvedDeviceID
        ioProcID = newProcID
        streamFormat = format
        formatDescription = fmtDesc
        isCapturing = true
        isIOProcActive = true

        micCaptureLog.info("""
            mic capture started \
            device=\(resolvedDeviceID, privacy: .public) \
            sampleRate=\(format.mSampleRate, privacy: .public) \
            channels=\(format.mChannelsPerFrame, privacy: .public)
            """)
    }

    func stopCapture() {
        guard let procID = ioProcID, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            isCapturing = false
            isIOProcActive = false
            return
        }
        if isIOProcActive {
            let stopStatus = AudioDeviceStop(deviceID, procID)
            if stopStatus != noErr {
                micCaptureLog.warning(
                    "AudioDeviceStop failed: \(stopStatus, privacy: .public)"
                )
            }
            isIOProcActive = false
        }
        let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, procID)
        if destroyStatus != noErr {
            micCaptureLog.warning(
                "AudioDeviceDestroyIOProcID failed: \(destroyStatus, privacy: .public)"
            )
        }
        deviceID = AudioDeviceID(kAudioObjectUnknown)
        ioProcID = nil
        formatDescription = nil
        isCapturing = false
    }

    /// Pause/resume the device IOProc without destroying it. Used by the
    /// mic-probe path so other apps' `kAudioDevicePropertyDeviceIsRunningSomewhere`
    /// state reflects only their usage, not ours.
    ///
    /// Idempotent: calling repeatedly with the same value is a no-op, avoiding
    /// spurious `AudioDeviceStart`/`AudioDeviceStop` OSStatus warnings (CoreAudio
    /// returns `kAudioHardwareNotRunningError` for redundant stops).
    func setActive(_ active: Bool) {
        guard let procID = ioProcID, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        guard active != isIOProcActive else { return }
        let status: OSStatus = active
            ? AudioDeviceStart(deviceID, procID)
            : AudioDeviceStop(deviceID, procID)
        if status != noErr {
            micCaptureLog.warning(
                "setActive(\(active, privacy: .public)) failed: \(status, privacy: .public)"
            )
            return
        }
        isIOProcActive = active
    }

    func forceReset() {
        stopCapture()
    }

    // MARK: - Device Resolution

    private func resolveDeviceID(uid: String?) throws -> AudioDeviceID {
        if let uid, !uid.isEmpty {
            do {
                return try translateUIDToDeviceID(uid)
            } catch {
                micCaptureLog.warning("""
                    UID '\(uid, privacy: .public)' did not resolve \
                    (\(error.localizedDescription, privacy: .public)), \
                    falling back to default input
                    """)
            }
        }
        return try getDefaultInputDevice()
    }

    private func getDefaultInputDevice() throws -> AudioDeviceID {
        var device: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try checkOSStatus(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size, &device
            ),
            operation: "kAudioHardwarePropertyDefaultInputDevice"
        )
        guard device != AudioDeviceID(kAudioObjectUnknown) else {
            throw MicrophoneCoreAudioError.operationFailed("no default input device available")
        }
        return device
    }

    private func translateUIDToDeviceID(_ uid: String) throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
        // kAudioHardwarePropertyDeviceForUID takes an AudioValueTranslation
        // whose mInputData points to a CFString (UID) and mOutputData receives
        // the AudioDeviceID. Pointers must remain valid for the duration of
        // the call.
        try withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
            var cfString = uid as CFString
            try withUnsafeMutablePointer(to: &cfString) { stringPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(stringPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(deviceIDPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDeviceForUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                try checkOSStatus(
                    AudioObjectGetPropertyData(
                        AudioObjectID(kAudioObjectSystemObject),
                        &address, 0, nil, &size, &translation
                    ),
                    operation: "kAudioHardwarePropertyDeviceForUID"
                )
            }
        }
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw MicrophoneCoreAudioError.operationFailed("UID '\(uid)' resolved to unknown device")
        }
        return deviceID
    }

    private func readStreamFormat(deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        try checkOSStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format),
            operation: "kAudioDevicePropertyStreamFormat (input)"
        )
        return format
    }

    private func makeFormatDescription(for format: AudioStreamBasicDescription) throws -> CMAudioFormatDescription {
        var mutableFormat = format
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &mutableFormat,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw MicrophoneCoreAudioError.osStatus("CMAudioFormatDescriptionCreate", status)
        }
        return formatDescription
    }

    // MARK: - Buffer Conversion (mirrors ProcessTapSystemAudioCapture)

    private struct CapturedAudioPacket: Sendable {
        let data: Data
        let frameCount: CMItemCount
        let presentationTime: CMTime
    }

    private static func copyAudioPacket(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>?,
        format: AudioStreamBasicDescription
    ) -> CapturedAudioPacket? {
        let firstBuffer = audioBufferList.pointee.mBuffers
        // Defense in depth: `startCapture` already rejects non-interleaved
        // multi-channel formats up-front, but if a driver under-reports its
        // format flags we could still receive `mNumberBuffers > 1` here.
        // Drop silently rather than produce a CMSampleBuffer that only
        // contains channel 0 with a multi-channel description.
        guard audioBufferList.pointee.mNumberBuffers == 1,
              let sourceData = firstBuffer.mData,
              firstBuffer.mDataByteSize > 0 else {
            return nil
        }

        let dataSize = Int(firstBuffer.mDataByteSize)
        let bytesPerFrame = Int(format.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }

        let frameCount = dataSize / bytesPerFrame
        guard frameCount > 0 else { return nil }

        return CapturedAudioPacket(
            data: Data(bytes: sourceData, count: dataSize),
            frameCount: CMItemCount(frameCount),
            presentationTime: presentationTime(from: inputTime, sampleRate: format.mSampleRate)
        )
    }

    private static func makeSampleBuffer(
        from packet: CapturedAudioPacket,
        formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        var replaceStatus = kCMBlockBufferNoErr
        packet.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                replaceStatus = -1
                return
            }
            replaceStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.data.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: packet.frameCount,
            presentationTimeStamp: packet.presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }

    private static func presentationTime(
        from timestamp: UnsafePointer<AudioTimeStamp>?,
        sampleRate: Double
    ) -> CMTime {
        if let timestamp {
            let value = timestamp.pointee
            if value.mFlags.contains(.sampleTimeValid), sampleRate > 0 {
                return CMTime(
                    value: Int64(value.mSampleTime.rounded()),
                    timescale: CMTimeScale(Int32(sampleRate.rounded()))
                )
            }
            if value.mFlags.contains(.hostTimeValid) {
                return CMClockMakeHostTimeFromSystemUnits(value.mHostTime)
            }
        }
        return CMClockGetTime(CMClockGetHostTimeClock())
    }

    // MARK: - OSStatus check

    private func checkOSStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw MicrophoneCoreAudioError.osStatus(operation, status)
        }
    }
}

enum MicrophoneCoreAudioError: Error, LocalizedError {
    case operationFailed(String)
    case invalidFormat(String)
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            return message
        case .invalidFormat(let details):
            return "Microphone format invalid (\(details))"
        case .osStatus(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}
