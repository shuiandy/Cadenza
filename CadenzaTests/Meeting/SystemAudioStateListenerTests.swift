import AudioToolbox
import Testing
@testable import Cadenza

@Suite("SystemAudioStateListener")
struct SystemAudioStateListenerTests {

    // MARK: - Helpers

    private static let chromeHelper = "com.google.Chrome.helper"
    private static let zoom = "us.zoom.xos"
    private static let unrelated = "com.example.player"
    private static let builtInMic: AudioObjectID = 84

    private static let processList = kAudioHardwarePropertyProcessObjectList
    private static let processDevices = kAudioProcessPropertyDevices
    private static let deviceRunning = kAudioDevicePropertyDeviceIsRunningSomewhere
    private static let deviceList = kAudioHardwarePropertyDevices
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private func makeListener(
        hardware: FakeAudioHardware,
        watching watched: Set<String> = [SystemAudioStateListenerTests.chromeHelper, SystemAudioStateListenerTests.zoom]
    ) -> (SystemAudioStateListener, Counter) {
        let listener = SystemAudioStateListener(watchedProcessBundleIDs: watched, hardware: hardware)
        let counter = Counter()
        listener.onAudioStateChanged = { counter.value += 1 }
        return (listener, counter)
    }

    // MARK: - Registration

    @Test func start_listensOnlyToWatchedProcesses() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper)
        hardware.addProcess(11, bundleID: Self.unrelated)
        let (listener, _) = makeListener(hardware: hardware)

        listener.startListening()

        #expect(hardware.listenerCount(on: 10, selector: Self.processDevices, scope: kAudioObjectPropertyScopeInput) == 1)
        #expect(hardware.listenerCount(on: 11, selector: Self.processDevices) == 0)
        #expect(hardware.listenerCount(on: Self.systemObject, selector: Self.processList) == 1)
        #expect(hardware.listenerCount(on: Self.builtInMic, selector: Self.deviceRunning) == 1)
    }

    @Test func noWatchedBundleIDs_skipsProcessListeners() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper)
        let (listener, _) = makeListener(hardware: hardware, watching: [])

        listener.startListening()

        #expect(hardware.listenerCount(on: Self.systemObject, selector: Self.processList) == 0)
        #expect(hardware.listenerCount(on: 10, selector: Self.processDevices) == 0)
        #expect(hardware.listenerCount(on: Self.builtInMic, selector: Self.deviceRunning) == 1)
    }

    @Test func stop_removesEveryListener() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        listener.stopListening()
        hardware.setInputRunning(10, true)
        hardware.fire(on: 10, selector: Self.processDevices)

        #expect(hardware.totalListenerCount == 0)
        #expect(counter.value == 0)
    }

    // MARK: - Input Changes

    /// The 2026-10-02 regression: Teams keeps the input device running, so the
    /// device listener never fires when Chrome's helper opens the mic.
    @Test func watchedProcessStartsInput_onRunningDevice_notifies() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.setInputRunning(10, true)
        hardware.fire(on: 10, selector: Self.processDevices)
        #expect(counter.value == 1)

        hardware.setInputRunning(10, false)
        hardware.fire(on: 10, selector: Self.processDevices)
        #expect(counter.value == 2)
    }

    @Test func deviceListChangeWithoutInputFlip_doesNotNotify() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        // Output starting or stopping alone also changes the input-scope device list.
        hardware.fire(on: 10, selector: Self.processDevices)
        hardware.fire(on: 10, selector: Self.processDevices)

        #expect(counter.value == 0)
    }

    @Test func inputAlreadyRunningAtStart_notifiesOnlyOnRelease() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper, inputRunning: true)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.fire(on: 10, selector: Self.processDevices)
        #expect(counter.value == 0)

        hardware.setInputRunning(10, false)
        hardware.fire(on: 10, selector: Self.processDevices)
        #expect(counter.value == 1)
    }

    // MARK: - Process List Changes

    @Test func watchedProcessAppearsUsingInput_notifiesAndListens() {
        let hardware = FakeAudioHardware()
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.addProcess(12, bundleID: Self.zoom, inputRunning: true)
        hardware.fire(on: Self.systemObject, selector: Self.processList)

        #expect(counter.value == 1)
        #expect(hardware.listenerCount(on: 12, selector: Self.processDevices) == 1)
    }

    @Test func watchedProcessAppearsIdle_listensWithoutNotifying() {
        let hardware = FakeAudioHardware()
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.addProcess(12, bundleID: Self.zoom)
        hardware.fire(on: Self.systemObject, selector: Self.processList)
        #expect(counter.value == 0)

        hardware.setInputRunning(12, true)
        hardware.fire(on: 12, selector: Self.processDevices)
        #expect(counter.value == 1)
    }

    @Test func watchedProcessExitsWhileUsingInput_notifies() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper, inputRunning: true)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.removeProcess(10)
        hardware.fire(on: Self.systemObject, selector: Self.processList)

        #expect(counter.value == 1)
        #expect(hardware.listenerCount(on: 10, selector: Self.processDevices) == 0)
    }

    @Test func idleWatchedProcessExits_doesNotNotify() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.removeProcess(10)
        hardware.fire(on: Self.systemObject, selector: Self.processList)

        #expect(counter.value == 0)
        #expect(hardware.listenerCount(on: 10, selector: Self.processDevices) == 0)
    }

    @Test func unrelatedProcessChurn_doesNotNotify_andReadsBundleIDOnce() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.addProcess(20, bundleID: Self.unrelated, inputRunning: true)
        hardware.fire(on: Self.systemObject, selector: Self.processList)
        hardware.fire(on: Self.systemObject, selector: Self.processList)

        #expect(counter.value == 0)
        #expect(hardware.bundleIDReads[20] == 1)
        #expect(hardware.bundleIDReads[10] == 1)
        #expect(hardware.listenerCount(on: 20, selector: Self.processDevices) == 0)
    }

    @Test func repeatedProcessListNotification_registersOnce() {
        let hardware = FakeAudioHardware()
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.addProcess(12, bundleID: Self.zoom, inputRunning: true)
        hardware.fire(on: Self.systemObject, selector: Self.processList)
        hardware.fire(on: Self.systemObject, selector: Self.processList)

        #expect(counter.value == 1)
        #expect(hardware.listenerCount(on: 12, selector: Self.processDevices) == 1)
    }

    @Test func unreadableProcessList_keepsExistingListeners() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(10, bundleID: Self.chromeHelper, inputRunning: true)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.processListReadable = false
        hardware.fire(on: Self.systemObject, selector: Self.processList)

        #expect(counter.value == 0)
        #expect(hardware.listenerCount(on: 10, selector: Self.processDevices) == 1)
    }

    @Test func unreadableBundleID_isRetriedOnNextChange() {
        let hardware = FakeAudioHardware()
        hardware.addProcess(12, bundleID: nil, inputRunning: true)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()
        #expect(hardware.listenerCount(on: 12, selector: Self.processDevices) == 0)

        hardware.setBundleID(12, Self.zoom)
        hardware.fire(on: Self.systemObject, selector: Self.processList)

        #expect(counter.value == 1)
        #expect(hardware.listenerCount(on: 12, selector: Self.processDevices) == 1)
    }

    // MARK: - Watched Bundle IDs

    @Test func defaultWatchSet_coversEveryProcessTheDetectorReads() {
        let watched = MeetingApp.processInputListenerBundleIdentifiers

        for app in MeetingApp.allCases {
            #expect(watched.isSuperset(of: app.audioBundleIdentifiers))
            #expect(watched.isSuperset(of: app.continuityAudioBundleIdentifiers))
        }
        #expect(watched.isSuperset(of: BrowserMeetingFamily.allAudioBundleIDs))
        #expect(watched.contains(Self.chromeHelper))
    }

    // MARK: - Device Listener

    /// macOS 27 posts `DeviceIsRunningSomewhere` only in the global scope, so an
    /// input-scope registration never fires.
    @Test func deviceListener_registersInEveryScope() {
        let hardware = FakeAudioHardware()
        let (listener, _) = makeListener(hardware: hardware)

        listener.startListening()

        #expect(hardware.listenerCount(on: Self.builtInMic, selector: Self.deviceRunning, scope: kAudioObjectPropertyScopeWildcard) == 1)
        #expect(hardware.listenerCount(on: 89, selector: Self.deviceRunning) == 0)
    }

    @Test func inputDeviceStartsAndStops_notifies() {
        let hardware = FakeAudioHardware()
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.setDeviceRunningInput(Self.builtInMic, true)
        hardware.fire(on: Self.builtInMic, selector: Self.deviceRunning)
        #expect(counter.value == 1)

        hardware.setDeviceRunningInput(Self.builtInMic, false)
        hardware.fire(on: Self.builtInMic, selector: Self.deviceRunning)
        #expect(counter.value == 2)
    }

    @Test func deviceNotificationWithoutInputFlip_doesNotNotify() {
        let hardware = FakeAudioHardware()
        hardware.setDeviceRunningInput(Self.builtInMic, true)
        let (listener, counter) = makeListener(hardware: hardware)
        listener.startListening()

        // A combined device starting or stopping playback posts the same property.
        hardware.fire(on: Self.builtInMic, selector: Self.deviceRunning)

        #expect(counter.value == 0)
    }

    @Test func removedDevice_dropsItsListener() {
        let hardware = FakeAudioHardware()
        let (listener, _) = makeListener(hardware: hardware)
        listener.startListening()

        hardware.removeDevice(Self.builtInMic)
        hardware.fire(on: Self.systemObject, selector: Self.deviceList)

        #expect(hardware.listenerCount(on: Self.builtInMic, selector: Self.deviceRunning) == 0)
    }
}

// MARK: - Fakes

private final class Counter {
    var value = 0
}

/// In-memory HAL: an input device and an output device, a mutable process
/// list, and listener blocks that tests fire by hand.
private final class FakeAudioHardware: AudioHardwareAccessing {
    private struct Process {
        var bundleID: String?
        var isRunningInput: Bool
    }

    private struct Registration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    var processListReadable = true
    private var devices: [AudioObjectID] = [84, 89]
    private let inputDevices: Set<AudioObjectID> = [84]
    private var runningInputDevices: Set<AudioObjectID> = []
    private(set) var bundleIDReads: [AudioObjectID: Int] = [:]
    private var processOrder: [AudioObjectID] = []
    private var processes: [AudioObjectID: Process] = [:]
    private var registrations: [Registration] = []

    var totalListenerCount: Int { registrations.count }

    func addProcess(_ objectID: AudioObjectID, bundleID: String?, inputRunning: Bool = false) {
        processOrder.append(objectID)
        processes[objectID] = Process(bundleID: bundleID, isRunningInput: inputRunning)
    }

    func removeProcess(_ objectID: AudioObjectID) {
        processOrder.removeAll { $0 == objectID }
        processes[objectID] = nil
    }

    func setInputRunning(_ objectID: AudioObjectID, _ running: Bool) {
        processes[objectID]?.isRunningInput = running
    }

    func setBundleID(_ objectID: AudioObjectID, _ bundleID: String?) {
        processes[objectID]?.bundleID = bundleID
    }

    func setDeviceRunningInput(_ deviceID: AudioObjectID, _ running: Bool) {
        if running {
            runningInputDevices.insert(deviceID)
        } else {
            runningInputDevices.remove(deviceID)
        }
    }

    func removeDevice(_ deviceID: AudioObjectID) {
        devices.removeAll { $0 == deviceID }
    }

    func listenerCount(
        on objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope? = nil
    ) -> Int {
        registrations.filter {
            $0.objectID == objectID
                && $0.address.mSelector == selector
                && (scope == nil || $0.address.mScope == scope)
        }.count
    }

    /// Invokes every block registered for the selector on the object, the way
    /// the HAL would on the main queue.
    func fire(on objectID: AudioObjectID, selector: AudioObjectPropertySelector) {
        let matching = registrations.filter { $0.objectID == objectID && $0.address.mSelector == selector }
        for registration in matching {
            withUnsafePointer(to: registration.address) { registration.block(1, $0) }
        }
    }

    // MARK: AudioHardwareAccessing

    func deviceIDs() -> [AudioObjectID] { devices }

    func deviceHasInputStreams(_ deviceID: AudioObjectID) -> Bool { inputDevices.contains(deviceID) }

    func isDeviceRunningInput(_ deviceID: AudioObjectID) -> Bool { runningInputDevices.contains(deviceID) }

    func processObjectIDs() -> [AudioObjectID]? {
        processListReadable ? processOrder : nil
    }

    func bundleID(ofProcess objectID: AudioObjectID) -> String? {
        bundleIDReads[objectID, default: 0] += 1
        return processes[objectID]?.bundleID
    }

    func isRunningInput(process objectID: AudioObjectID) -> Bool {
        processes[objectID]?.isRunningInput ?? false
    }

    func addListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        to objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> OSStatus {
        let isProcessObject = processes[objectID] != nil
        let isKnownObject = objectID == AudioObjectID(kAudioObjectSystemObject)
            || deviceIDs().contains(objectID)
            || isProcessObject
        guard isKnownObject else { return OSStatus(kAudioHardwareBadObjectError) }
        registrations.append(Registration(objectID: objectID, address: address, block: block))
        return noErr
    }

    func removeListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        from objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) {
        registrations.removeAll {
            $0.objectID == objectID
                && $0.address.mSelector == address.mSelector
                && $0.address.mScope == address.mScope
        }
    }
}
