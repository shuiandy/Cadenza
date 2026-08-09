import CoreGraphics
import Foundation

/// Enumerates on-screen windows via the legacy CGWindowList API.
///
/// Why not `SCShareableContent`?
/// `SCShareableContent` goes through `replayd`. On macOS 26.4 there is a
/// systemstatusd O(n²) cache pathology where `replayd`'s frequent attribution
/// publishes pin systemstatusd at 100% CPU and break unrelated SCK clients
/// (notably Microsoft Teams' screen sharing). `CGWindowListCopyWindowInfo` is
/// a windowserver query and does not touch replayd.
///
/// We still preflight Screen Recording permission before calling it because
/// automatic/background polling must never cause screen-recording permission
/// behavior. Without permission, window snapshots are simply unavailable.
enum CGWindowEnumerator {

    /// One window's metadata, keyed by PID for downstream filtering.
    struct EnumeratedWindow: Sendable {
        let pid: pid_t
        let snapshot: MeetingWindowAnalyzer.WindowSnapshot
    }

    /// Snapshot all on-screen, non-desktop windows. Filters out the menu bar /
    /// dock layer (`kCGWindowLayer != 0` for system UI) so the heuristics see
    /// only normal app windows.
    static func snapshotOnScreenWindows(
        screenCaptureAccessAvailable: Bool = CGPreflightScreenCaptureAccess()
    ) -> [EnumeratedWindow] {
        guard screenCaptureAccessAvailable else {
            return []
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [EnumeratedWindow] = []
        result.reserveCapacity(raw.count)

        for entry in raw {
            // Layer 0 = normal app windows. System UI (menu bar, dock, status bar)
            // sits at higher layers and would skew the "significant window count"
            // heuristics if included.
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }

            guard let pidNumber = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            let pid = pid_t(pidNumber)

            let title = entry[kCGWindowName as String] as? String

            // Bounds dictionary: { X, Y, Width, Height } — values are CGFloat.
            let width: CGFloat
            let height: CGFloat
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
               let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                width = cgRect.width
                height = cgRect.height
            } else {
                width = 0
                height = 0
            }

            // We pre-filtered with `.optionOnScreenOnly`, so isOnScreen is implicitly true.
            // The snapshot type still carries the flag for the shared analyzer API.
            let snapshot = MeetingWindowAnalyzer.WindowSnapshot(
                title: title,
                width: width,
                height: height,
                isOnScreen: true
            )
            result.append(EnumeratedWindow(pid: pid, snapshot: snapshot))
        }

        return result
    }
}
