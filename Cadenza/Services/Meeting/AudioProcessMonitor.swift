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

// MARK: - HAL Access

/// The CoreAudio HAL reads and listener registrations behind the audio state
/// listener, abstracted so its bookkeeping can be tested without real audio
/// objects. Every call reads a property or registers a listener. None opens an
/// audio stream, so none can trigger a microphone permission prompt.
protocol AudioHardwareAccessing {
    func deviceIDs() -> [AudioObjectID]
    func deviceHasInputStreams(_ deviceID: AudioObjectID) -> Bool
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` read in the input scope.
    func isDeviceRunningInput(_ deviceID: AudioObjectID) -> Bool
    /// `nil` when the list cannot be read, as opposed to an empty list.
    func processObjectIDs() -> [AudioObjectID]?
    func bundleID(ofProcess objectID: AudioObjectID) -> String?
    func isRunningInput(process objectID: AudioObjectID) -> Bool
    /// Registers `block` to run on the main queue.
    func addListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        to objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> OSStatus
    func removeListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        from objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    )
}

// MARK: - Audio State Listener

protocol AudioStateListening: AnyObject {
    var onAudioStateChanged: (() -> Void)? { get set }
    func startListening()
    func stopListening()
}

/// Wakes the meeting detector when microphone use changes, so detection does
/// not wait for the idle poll.
///
/// Two sources:
/// - `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device. It
///   only changes when the first client opens a device or the last one closes
///   it, so it goes silent while another process (e.g. Teams' `modulehost`,
///   which never lets go) keeps the default input running. On macOS 27 the HAL
///   posts it only in the global scope, so a listener registered in the input
///   scope never fires; the listener registers in every scope and reads the
///   input-scope value to ignore output-only changes on combined devices.
/// - `kAudioProcessPropertyDevices` (input scope) on each process object whose
///   bundle ID is watched. It changes whenever that process starts or stops an
///   input stream, even on a device that is already running. On macOS 27,
///   `kAudioProcessPropertyIsRunningInput` itself never notifies (measured
///   2026-10-02 with AUHAL and VoiceProcessingIO clients), so the listener
///   watches the device list and reads `IsRunningInput` when it changes.
final class SystemAudioStateListener: AudioStateListening {
    var onAudioStateChanged: (() -> Void)?

    private let hardware: any AudioHardwareAccessing
    private let watchedProcessBundleIDs: Set<String>

    private struct DeviceEntry {
        let block: AudioObjectPropertyListenerBlock
        var isRunningInput: Bool
    }

    private var deviceListBlock: AudioObjectPropertyListenerBlock?
    private var deviceEntries: [AudioObjectID: DeviceEntry] = [:]
    private var isListeningForDeviceChanges = false

    private struct ProcessEntry {
        let bundleID: String
        let block: AudioObjectPropertyListenerBlock
        var isRunningInput: Bool
    }

    private var processListBlock: AudioObjectPropertyListenerBlock?
    private var processEntries: [AudioObjectID: ProcessEntry] = [:]
    /// Bundle ID of every process object seen so far, so a process-list change
    /// only reads the bundle IDs of new objects. Walking all of them costs
    /// several milliseconds on the main thread, and the list changes whenever
    /// any process starts or stops using audio.
    private var knownProcessBundleIDs: [AudioObjectID: String] = [:]

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Every scope: macOS 27 posts this property only in the global scope,
    /// which an input-scope registration does not match (measured 2026-10-02).
    private static let deviceRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let processInputDevicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    init(
        watchedProcessBundleIDs: Set<String> = MeetingApp.processInputListenerBundleIdentifiers,
        hardware: any AudioHardwareAccessing = SystemAudioHardware()
    ) {
        self.watchedProcessBundleIDs = watchedProcessBundleIDs
        self.hardware = hardware
    }

    func startListening() {
        registerDeviceListListener()
        registerInputDeviceListeners()
        registerProcessListListener()
        refreshProcessListeners()
    }

    func stopListening() {
        removeAllListeners()
        onAudioStateChanged = nil
    }

    deinit {
        removeAllListeners()
    }

    // MARK: - Device Listeners

    private func registerDeviceListListener() {
        guard !isListeningForDeviceChanges else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.registerInputDeviceListeners()
            self?.onAudioStateChanged?()
        }

        let status = hardware.addListener(
            block,
            to: AudioObjectID(kAudioObjectSystemObject),
            address: Self.deviceListAddress
        )

        guard status == noErr else {
            NSLog("[MeetingDetector] audio listener: failed to register device list listener (status=%d)", status)
            return
        }

        deviceListBlock = block
        isListeningForDeviceChanges = true
    }

    private func registerInputDeviceListeners() {
        let deviceIDs = hardware.deviceIDs()
        let current = Set(deviceIDs)
        for (deviceID, entry) in deviceEntries where !current.contains(deviceID) {
            hardware.removeListener(entry.block, from: deviceID, address: Self.deviceRunningAddress)
            deviceEntries[deviceID] = nil
        }

        for deviceID in deviceIDs where deviceEntries[deviceID] == nil && hardware.deviceHasInputStreams(deviceID) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceRunningChanged(deviceID)
            }

            let status = hardware.addListener(block, to: deviceID, address: Self.deviceRunningAddress)

            guard status == noErr else {
                NSLog("[MeetingDetector] audio listener: failed to register input listener (device=%u status=%d)", deviceID, status)
                continue
            }

            deviceEntries[deviceID] = DeviceEntry(block: block, isRunningInput: hardware.isDeviceRunningInput(deviceID))
        }
    }

    private func deviceRunningChanged(_ deviceID: AudioObjectID) {
        guard var entry = deviceEntries[deviceID] else { return }

        // The global-scope notification also fires when a device with output
        // streams (a headset, Teams' virtual device) starts or stops playback.
        let isRunningInput = hardware.isDeviceRunningInput(deviceID)
        guard isRunningInput != entry.isRunningInput else { return }

        entry.isRunningInput = isRunningInput
        deviceEntries[deviceID] = entry
        onAudioStateChanged?()
    }

    // MARK: - Process Listeners

    private func registerProcessListListener() {
        guard processListBlock == nil, !watchedProcessBundleIDs.isEmpty else { return }

        // The HAL posts this twice per change; the refresh is idempotent.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.refreshProcessListeners() else { return }
            self.onAudioStateChanged?()
        }

        let status = hardware.addListener(
            block,
            to: AudioObjectID(kAudioObjectSystemObject),
            address: Self.processListAddress
        )

        guard status == noErr else {
            NSLog("[MeetingDetector] audio listener: failed to register process list listener (status=%d)", status)
            return
        }

        processListBlock = block
    }

    /// Brings the per-process listeners in line with the HAL process list.
    /// Returns true when a watched process appeared already running input or
    /// vanished while running it: a microphone change that no per-process
    /// listener reports.
    @discardableResult
    private func refreshProcessListeners() -> Bool {
        guard !watchedProcessBundleIDs.isEmpty,
              let objectIDs = hardware.processObjectIDs() else { return false }

        let current = Set(objectIDs)
        var inputChanged = false

        for (objectID, entry) in processEntries where !current.contains(objectID) {
            // The object is gone, so the HAL normally rejects this removal.
            hardware.removeListener(entry.block, from: objectID, address: Self.processInputDevicesAddress)
            processEntries[objectID] = nil
            if entry.isRunningInput {
                NSLog("[MeetingDetector] audio listener: %@ exited while using input", entry.bundleID)
                inputChanged = true
            }
        }
        knownProcessBundleIDs = knownProcessBundleIDs.filter { current.contains($0.key) }

        for objectID in objectIDs where processEntries[objectID] == nil {
            let bundleID: String
            if let known = knownProcessBundleIDs[objectID] {
                bundleID = known
            } else {
                // Not cached when unreadable, so a later change retries it.
                guard let read = hardware.bundleID(ofProcess: objectID) else { continue }
                knownProcessBundleIDs[objectID] = read
                bundleID = read
            }
            guard watchedProcessBundleIDs.contains(bundleID) else { continue }
            if registerProcessListener(objectID, bundleID: bundleID) {
                inputChanged = true
            }
        }

        return inputChanged
    }

    /// Returns whether the process is already running input. The listener is
    /// registered before that read, so a microphone opened in between is seen
    /// by one or the other.
    private func registerProcessListener(_ objectID: AudioObjectID, bundleID: String) -> Bool {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.processInputDevicesChanged(objectID)
        }

        let status = hardware.addListener(block, to: objectID, address: Self.processInputDevicesAddress)

        guard status == noErr else {
            NSLog("[MeetingDetector] audio listener: failed to register process listener (%@ object=%u status=%d)", bundleID, objectID, status)
            return false
        }

        let isRunningInput = hardware.isRunningInput(process: objectID)
        processEntries[objectID] = ProcessEntry(bundleID: bundleID, block: block, isRunningInput: isRunningInput)
        return isRunningInput
    }

    private func processInputDevicesChanged(_ objectID: AudioObjectID) {
        guard var entry = processEntries[objectID] else { return }

        // The input-scope device list also changes when the process starts or
        // stops output alone (Chrome's helper plays sounds outside calls), so
        // only a flip of the input state wakes the detector.
        let isRunningInput = hardware.isRunningInput(process: objectID)
        guard isRunningInput != entry.isRunningInput else { return }

        entry.isRunningInput = isRunningInput
        processEntries[objectID] = entry
        NSLog("[MeetingDetector] audio listener: %@ input %@", entry.bundleID, isRunningInput ? "started" : "stopped")
        onAudioStateChanged?()
    }

    // MARK: - Teardown

    private func removeAllListeners() {
        if let block = deviceListBlock {
            hardware.removeListener(block, from: AudioObjectID(kAudioObjectSystemObject), address: Self.deviceListAddress)
            deviceListBlock = nil
            isListeningForDeviceChanges = false
        }

        for (deviceID, entry) in deviceEntries {
            hardware.removeListener(entry.block, from: deviceID, address: Self.deviceRunningAddress)
        }
        deviceEntries = [:]

        if let block = processListBlock {
            hardware.removeListener(block, from: AudioObjectID(kAudioObjectSystemObject), address: Self.processListAddress)
            processListBlock = nil
        }

        for (objectID, entry) in processEntries {
            hardware.removeListener(entry.block, from: objectID, address: Self.processInputDevicesAddress)
        }
        processEntries = [:]
        knownProcessBundleIDs = [:]
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
    private let hardware = SystemAudioHardware()

    func audioUsage(bundleIDs: [String]) -> [String: AudioProcessUsage] {
        let bundleSet = Set(bundleIDs)
        guard !bundleSet.isEmpty, let processObjects = hardware.processObjectIDs() else { return [:] }

        var result: [String: AudioProcessUsage] = [:]
        for objID in processObjects {
            guard let processBundleID = hardware.bundleID(ofProcess: objID),
                  bundleSet.contains(processBundleID) else { continue }
            let input = hardware.isRunningInput(process: objID)
            let output = hardware.isRunningOutput(process: objID)
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
}

/// Direct CoreAudio HAL calls. Stateless and safe to call from any thread;
/// listeners are delivered on the main queue.
struct SystemAudioHardware: AudioHardwareAccessing {

    func deviceIDs() -> [AudioObjectID] {
        objectIDs(of: kAudioHardwarePropertyDevices) ?? []
    }

    func deviceHasInputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    func isDeviceRunningInput(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    func processObjectIDs() -> [AudioObjectID]? {
        objectIDs(of: kAudioHardwarePropertyProcessObjectList)
    }

    func bundleID(ofProcess objectID: AudioObjectID) -> String? {
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

    func isRunningInput(process objectID: AudioObjectID) -> Bool {
        readFlag(kAudioProcessPropertyIsRunningInput, of: objectID)
    }

    func isRunningOutput(process objectID: AudioObjectID) -> Bool {
        readFlag(kAudioProcessPropertyIsRunningOutput, of: objectID)
    }

    func addListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        to objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> OSStatus {
        var address = address
        return AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
    }

    func removeListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        from objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) {
        var address = address
        AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
    }

    // MARK: - Helpers

    private func objectIDs(of selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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

    private func readFlag(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
}
