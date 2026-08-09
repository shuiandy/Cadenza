#!/usr/bin/env swift
// Diagnostic: dump all audio processes visible to Process Audio Object API.
// Run while in a Teams call to verify Teams shows up.
//
// Usage: swift scripts/diagnose_audio_processes.swift

import AudioToolbox
import Foundation

func readProcessList() -> [AudioObjectID] {
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
    guard status == noErr, dataSize > 0 else {
        print("ERROR: Cannot read process list (status=\(status))")
        return []
    }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var objectIDs = [AudioObjectID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &dataSize, &objectIDs
    )
    guard status == noErr else {
        print("ERROR: Cannot read process data (status=\(status))")
        return []
    }
    return objectIDs
}

func readBundleID(_ objectID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var bundleID: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &bundleID) { ptr in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
    }
    guard status == noErr else { return nil }
    let result = bundleID as String
    return result.isEmpty ? nil : result
}

func readIsRunningInput(_ objectID: AudioObjectID) -> Bool {
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

func readIsRunningOutput(_ objectID: AudioObjectID) -> Bool {
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

// Main
let meetingBundleIDs: Set<String> = [
    "us.zoom.xos",
    "com.microsoft.teams", "com.microsoft.teams2",
    "com.cisco.webexmeetingsapp",
    "com.apple.FaceTime",
    "com.tinyspeck.slackmacgap"
]

let processObjects = readProcessList()
print("=== Audio Process Diagnostic ===")
print("Total audio processes: \(processObjects.count)\n")

var meetingFound = false
for objID in processObjects {
    guard let bundleID = readBundleID(objID) else { continue }
    let input = readIsRunningInput(objID)
    let output = readIsRunningOutput(objID)
    let isMeeting = meetingBundleIDs.contains(bundleID)

    if isMeeting {
        meetingFound = true
        print("★ MEETING APP: \(bundleID)")
        print("  audioObjectID: \(objID)")
        print("  isRunningInput (mic): \(input)")
        print("  isRunningOutput (speaker): \(output)")
        print()
    }
}

if !meetingFound {
    print("⚠️  No meeting apps found in audio process list.")
    print("   This means no meeting app has opened an audio connection yet.\n")
}

print("--- All audio processes ---")
for objID in processObjects {
    guard let bundleID = readBundleID(objID) else { continue }
    let input = readIsRunningInput(objID)
    let output = readIsRunningOutput(objID)
    let marker = (input || output) ? "🔊" : "  "
    print("\(marker) \(bundleID) (input=\(input), output=\(output))")
}
