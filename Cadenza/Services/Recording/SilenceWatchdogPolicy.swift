import Foundation

/// Decision logic for the sustained-silence watchdog — pure value type, all
/// inputs injected, so tests need no audio pipeline or real clock.
///
/// Guards (all must hold — see spec 2026-07-06-silent-tail-handling):
/// - `thresholdMinutes > 0`: the `silenceWatchdogMinutes` default is the
///   master switch (≤0 disables; no Settings UI, `defaults write` only).
/// - `autoStopEnabled`: the watchdog is a flavor of auto-stop and obeys the
///   user-visible "Auto-stop when mic closes" toggle.
/// - `isAutoStartedRecording`: manual recordings are never watchdog-stopped —
///   the user may be intentionally recording long silence.
/// - `!perProcessMicEverActive`: sessions with a real per-process mic signal
///   (Zoom, FaceTime) are protected. NOTE: Teams never produces this signal
///   (its audio lives in a subprocess), so the watchdog covers ALL auto-started
///   Teams recordings by design — Teams is exactly the problem scenario.
/// - `!suppressedByUser`: "Keep recording" suppresses for this recording.
struct SilenceWatchdogPolicy {
    var thresholdMinutes: Int
    var autoStopEnabled: Bool
    var isAutoStartedRecording: Bool
    var perProcessMicEverActive: Bool
    var suppressedByUser: Bool

    func shouldTrigger(silenceDuration: TimeInterval) -> Bool {
        guard thresholdMinutes > 0 else { return false }
        guard autoStopEnabled,
              isAutoStartedRecording,
              !perProcessMicEverActive,
              !suppressedByUser else { return false }
        return silenceDuration >= TimeInterval(thresholdMinutes * 60)
    }
}
