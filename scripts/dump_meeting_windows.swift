#!/usr/bin/env swift

import AppKit
import Foundation
import ScreenCaptureKit

struct MeetingProcess {
    let bundleID: String
    let name: String
    let pid: pid_t
}

let meetingBundleIDs: Set<String> = [
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "com.cisco.webexmeetingsapp",
    "com.apple.FaceTime",
    "com.tinyspeck.slackmacgap"
]

func sanitizeTitle(_ value: String?) -> String {
    guard let value else { return "<empty>" }
    let line = value
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? "<empty>" : line
}

func runningMeetingProcesses() -> [MeetingProcess] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard let bundleID = app.bundleIdentifier,
              meetingBundleIDs.contains(bundleID) else {
            return nil
        }

        return MeetingProcess(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            pid: app.processIdentifier
        )
    }
}

func parseInterval(arguments: [String]) -> TimeInterval {
    guard let index = arguments.firstIndex(of: "--interval"),
          arguments.indices.contains(index + 1),
          let interval = TimeInterval(arguments[index + 1]),
          interval > 0 else {
        return 2
    }

    return interval
}

func dumpWindows() async {
    let apps = runningMeetingProcesses()
    let timestamp = ISO8601DateFormatter().string(from: Date())

    print("=== Meeting Window Dump @ \(timestamp) ===")
    if apps.isEmpty {
        print("No meeting apps are running.")
        return
    }

    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        for app in apps {
            let windows = content.windows
                .filter { $0.owningApplication?.processID == app.pid }
                .sorted { lhs, rhs in
                    (lhs.frame.width * lhs.frame.height) > (rhs.frame.width * rhs.frame.height)
                }

            print("\n[\(app.name)] bundle=\(app.bundleID) pid=\(app.pid) windows=\(windows.count)")
            for (index, window) in windows.enumerated() {
                let title = sanitizeTitle(window.title)
                let onScreen = window.isOnScreen ? 1 : 0
                print("  #\(index + 1) onScreen=\(onScreen) frame=\(Int(window.frame.width))x\(Int(window.frame.height)) title=\(title)")
            }
        }
    } catch {
        print("ERROR: Failed to query SCShareableContent: \(error.localizedDescription)")
    }
}

let arguments = CommandLine.arguments
let isWatchMode = arguments.contains("--watch")
let interval = parseInterval(arguments: arguments)

Task {
    repeat {
        await dumpWindows()
        if !isWatchMode {
            break
        }

        print("\n--- waiting \(interval)s ---\n")
        try? await Task.sleep(for: .seconds(interval))
    } while true

    CFRunLoopStop(CFRunLoopGetMain())
}

RunLoop.main.run()
