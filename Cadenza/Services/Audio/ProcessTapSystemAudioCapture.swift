import CoreAudio
import CoreAudioTypes
import CoreMedia
import Foundation

/// Captures system audio through Core Audio process taps instead of ScreenCaptureKit.
///
/// This avoids the ScreenCaptureKit/replayd path entirely. That matters because replayd
/// can continuously publish capture attribution while recording, which in turn can pin
/// systemstatusd/reportd on affected macOS builds and interfere with other SCK clients
/// such as Microsoft Teams screen sharing.
final class ProcessTapSystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isCapturing = false
    private let callbackQueue = DispatchQueue(label: "com.shuiandy.Cadenza.processTapAudio", qos: .utility)

    var onSystemAudio: (@Sendable (CMSampleBuffer) -> Void)?

    var hasActiveResources: Bool {
        isCapturing
            || tapID != AudioObjectID(kAudioObjectUnknown)
            || aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
            || ioProcID != nil
    }

    func startCapture(targetBundleID: String? = nil) throws {
        guard !isCapturing else { return }

        let description = makeTapDescription(targetBundleID: targetBundleID)
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try checkOSStatus(
            AudioHardwareCreateProcessTap(description, &newTapID),
            operation: "AudioHardwareCreateProcessTap"
        )

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var newIOProcID: AudioDeviceIOProcID?

        do {
            let tapUID = try readTapUID(newTapID)
            let tapFormat = try readTapFormat(newTapID)
            let formatDescription = try makeFormatDescription(for: tapFormat)

            let aggregateDescription = makeAggregateDescription(tapUID: tapUID)
            try checkOSStatus(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID),
                operation: "AudioHardwareCreateAggregateDevice"
            )

            let audioHandler = onSystemAudio
            let callbackQueue = callbackQueue
            let ioBlock: AudioDeviceIOBlock = { [tapFormat, formatDescription, audioHandler, callbackQueue] _, inputData, inputTime, _, _ in
                guard let packet = Self.copyAudioPacket(
                        from: inputData,
                        inputTime: inputTime,
                        format: tapFormat
                      ) else { return }
                callbackQueue.async {
                    guard let sampleBuffer = Self.makeSampleBuffer(
                        from: packet,
                        formatDescription: formatDescription
                    ) else { return }
                    audioHandler?(sampleBuffer)
                }
            }

            try checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateDeviceID, nil, ioBlock),
                operation: "AudioDeviceCreateIOProcIDWithBlock"
            )
            guard let newIOProcID else {
                throw ProcessTapCaptureError.operationFailed("AudioDeviceCreateIOProcIDWithBlock returned nil")
            }

            try checkOSStatus(
                AudioDeviceStart(newAggregateDeviceID, newIOProcID),
                operation: "AudioDeviceStart"
            )

            tapID = newTapID
            aggregateDeviceID = newAggregateDeviceID
            ioProcID = newIOProcID
            isCapturing = true

            let target = targetBundleID?.isEmpty == false ? targetBundleID! : "global"
            NSLog(
                "[AudioCapture] Core Audio process tap started target=%@ sampleRate=%.0f channels=%u",
                target,
                tapFormat.mSampleRate,
                tapFormat.mChannelsPerFrame
            )
        } catch {
            destroyIOProc(newIOProcID, aggregateDeviceID: newAggregateDeviceID)
            destroyAggregateDevice(newAggregateDeviceID)
            destroyTap(newTapID)
            throw error
        }
    }

    func stopCapture() {
        destroyIOProc(ioProcID, aggregateDeviceID: aggregateDeviceID)
        ioProcID = nil

        destroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

        destroyTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isCapturing = false
    }

    func forceReset() {
        stopCapture()
    }

    // MARK: - Tap Setup

    private func makeTapDescription(targetBundleID: String?) -> CATapDescription {
        let description = CATapDescription()
        description.name = "Cadenza System Audio"
        description.isMono = true
        description.isMixdown = true
        description.isPrivate = true
        description.muteBehavior = .unmuted

        if let targetBundleID, !targetBundleID.isEmpty {
            description.isExclusive = false
            description.bundleIDs = Self.captureBundleIDs(for: targetBundleID)
            description.isProcessRestoreEnabled = true
        } else {
            description.isExclusive = true
            description.bundleIDs = [Bundle.main.bundleIdentifier ?? "com.shuiandy.Cadenza"]
            description.isProcessRestoreEnabled = true
        }

        return description
    }

    private static func captureBundleIDs(for bundleID: String) -> [String] {
        switch bundleID {
        case "com.microsoft.teams2":
            return ["com.microsoft.teams2", "com.microsoft.teams2.modulehost"]
        default:
            return [bundleID]
        }
    }

    private func makeAggregateDescription(tapUID: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Cadenza Process Tap",
            kAudioAggregateDeviceUIDKey: "com.shuiandy.Cadenza.ProcessTap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
    }

    private func readTapUID(_ tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedRef) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let unmanagedRef else {
            throw ProcessTapCaptureError.osStatus("kAudioTapPropertyUID", status)
        }
        return unmanagedRef.takeRetainedValue() as String
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
            operation: "kAudioTapPropertyFormat"
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
            throw ProcessTapCaptureError.osStatus("CMAudioFormatDescriptionCreate", status)
        }
        return formatDescription
    }

    private func destroyTap(_ tapID: AudioObjectID) {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            NSLog("[AudioCapture] AudioHardwareDestroyProcessTap failed: %d", status)
        }
    }

    private func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        if status != noErr {
            NSLog("[AudioCapture] AudioHardwareDestroyAggregateDevice failed: %d", status)
        }
    }

    private func destroyIOProc(_ procID: AudioDeviceIOProcID?, aggregateDeviceID: AudioObjectID) {
        guard let procID, aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let stopStatus = AudioDeviceStop(aggregateDeviceID, procID)
        if stopStatus != noErr {
            NSLog("[AudioCapture] AudioDeviceStop failed: %d", stopStatus)
        }

        let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        if destroyStatus != noErr {
            NSLog("[AudioCapture] AudioDeviceDestroyIOProcID failed: %d", destroyStatus)
        }
    }

    // MARK: - Buffer Conversion

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
        guard let sourceData = firstBuffer.mData,
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
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: packet.frameCount,
            presentationTimeStamp: packet.presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }

        return sampleBuffer
    }

    private static func presentationTime(from timestamp: UnsafePointer<AudioTimeStamp>?, sampleRate: Double) -> CMTime {
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

    private func checkOSStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw ProcessTapCaptureError.osStatus(operation, status)
        }
    }
}

enum ProcessTapCaptureError: Error, LocalizedError {
    case operationFailed(String)
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            return message
        case .osStatus(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}
