import AudioToolbox
import Foundation

// MARK: - Protocol

/// Per-process audio usage for a single bundle ID, as of one HAL snapshot.
/// `isRunningOutput` (audio playback) is a DIAGNOSTIC probe for Teams call-end
/// detection: unlike `isRunningInput` — which the Teams `modulehost` helper keeps
/// true even when idle — output is hypothesized to drop when a call actually ends.
struct AudioProcessUsage: Sendable {
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// Queries per-process audio state. Abstracted for testability.
protocol AudioProcessQuerying {
    /// One-shot snapshot mapping each of the given bundle IDs that is currently a
    /// running audio process to its input/output running state. A single HAL
    /// process-object-list walk answers every per-app input/output query within
    /// one evaluation pass, instead of re-walking the list once per query.
    /// Bundle IDs with no running audio process are absent from the result.
    func audioUsage(bundleIDs: [String]) -> [String: AudioProcessUsage]
}

// MARK: - Audio State Listener

protocol AudioStateListening: AnyObject {
    var onAudioStateChanged: (() -> Void)? { get set }
    func startListening()
    func stopListening()
}

final class SystemAudioStateListener: AudioStateListening {
    var onAudioStateChanged: (() -> Void)?

    private var deviceListBlock: AudioObjectPropertyListenerBlock?
    private var inputDeviceEntries: [(deviceID: AudioObjectID, block: AudioObjectPropertyListenerBlock)] = []
    private var isListeningForDeviceChanges = false

    func startListening() {
        registerDeviceListListener()
        registerInputDeviceListeners()
    }

    func stopListening() {
        removeAllListeners()
        onAudioStateChanged = nil
    }

    deinit {
        removeAllListeners()
    }

    // MARK: - Listener Registration

    private func registerDeviceListListener() {
        guard !isListeningForDeviceChanges else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.registerInputDeviceListeners()
            self?.onAudioStateChanged?()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )

        guard status == noErr else {
            NSLog("[MeetingDetector] audio listener: failed to register device list listener (status=%d)", status)
            return
        }

        deviceListBlock = block
        isListeningForDeviceChanges = true
    }

    private func registerInputDeviceListeners() {
        let registeredIDs = Set(inputDeviceEntries.map(\.deviceID))
        for deviceID in getAudioDeviceIDs() where deviceHasInputStreams(deviceID) {
            guard !registeredIDs.contains(deviceID) else { continue }

            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onAudioStateChanged?()
            }

            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                DispatchQueue.main,
                block
            )

            guard status == noErr else {
                NSLog("[MeetingDetector] audio listener: failed to register input listener (device=%u status=%d)", deviceID, status)
                continue
            }

            inputDeviceEntries.append((deviceID: deviceID, block: block))
        }
    }

    private func removeAllListeners() {
        if let block = deviceListBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            deviceListBlock = nil
            isListeningForDeviceChanges = false
        }

        for entry in inputDeviceEntries {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                entry.deviceID, &address, DispatchQueue.main, entry.block
            )
        }
        inputDeviceEntries = []
    }

    // MARK: - CoreAudio Helpers

    private func getAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs
    }

    private func deviceHasInputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }
}

// MARK: - System Implementation

/// Queries per-process audio via the Process Audio Object API (macOS 14.2+).
///
/// This API answers "which specific process is using the microphone" — unlike
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` which is system-wide and cannot
/// distinguish between Teams using mic for a meeting vs Siri using mic for dictation.
///
/// Key properties:
/// - `kAudioHardwarePropertyProcessObjectList` — enumerate all audio processes
/// - `kAudioProcessPropertyBundleID` — identify process by bundle ID
/// - `kAudioProcessPropertyIsRunningInput` — whether process is using mic input
/// - `kAudioProcessPropertyIsRunningOutput` — whether process is playing audio
///
/// Stateless: all methods are pure CoreAudio HAL queries, safe to call from any thread.
struct SystemAudioProcessQuery: AudioProcessQuerying {

    func audioUsage(bundleIDs: [String]) -> [String: AudioProcessUsage] {
        let bundleSet = Set(bundleIDs)
        guard !bundleSet.isEmpty, let processObjects = readProcessList() else { return [:] }

        var result: [String: AudioProcessUsage] = [:]
        for objID in processObjects {
            guard let processBundleID = readBundleID(objID),
                  bundleSet.contains(processBundleID) else { continue }
            let input = readIsRunningInput(objID)
            let output = readIsRunningOutput(objID)
            // Multiple audio process objects can share one bundle ID (helper
            // instances); OR their states so "any instance is using input/output"
            // is preserved — matching the old isAny* semantics.
            let existing = result[processBundleID]
            result[processBundleID] = AudioProcessUsage(
                isRunningInput: input || (existing?.isRunningInput ?? false),
                isRunningOutput: output || (existing?.isRunningOutput ?? false)
            )
        }
        return result
    }

    // MARK: - CoreAudio Helpers

    private func readProcessList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &objectIDs
        )
        guard status == noErr else { return nil }
        return objectIDs
    }

    private func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // CoreAudio returns a +1 retained CFStringRef. Use Unmanaged to take ownership
        // properly, avoiding the leak from writing a retained ref through a raw pointer.
        var unmanagedRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedRef) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged = unmanagedRef else { return nil }
        let result = unmanaged.takeRetainedValue() as String
        return result.isEmpty ? nil : result
    }

    private func readIsRunningInput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    private func readIsRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
}
