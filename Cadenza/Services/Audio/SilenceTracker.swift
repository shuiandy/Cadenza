import Foundation

/// Tracks when either audio path (system or microphone) last crossed the
/// silence threshold. Written from background capture callbacks, read from
/// the MainActor watchdog tick — single-word store, same @unchecked Sendable
/// tolerance as AudioMixer's PauseFlag.
final class SilenceTracker: @unchecked Sendable {

    /// Normalized-level silence threshold. Equals raw RMS 0.006 (-45dB, the
    /// AudioSilenceDetector threshold) after the `min(rms*5, 1)` normalization
    /// used by AudioLevelMeter.
    static let silenceLevelThreshold: Float = 0.03

    private let now: () -> TimeInterval
    private var lastNonSilent: TimeInterval

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
        self.lastNonSilent = now()
    }

    /// Feed a sampled level. nil means "buffer format unknown" — fail-open:
    /// it counts as audible so an unparseable format never reads as silence.
    func record(level: Float?) {
        guard let level else {
            lastNonSilent = now()
            return
        }
        if level > Self.silenceLevelThreshold {
            lastNonSilent = now()
        }
    }

    func reset() {
        lastNonSilent = now()
    }

    var silenceDuration: TimeInterval {
        max(0, now() - lastNonSilent)
    }
}
