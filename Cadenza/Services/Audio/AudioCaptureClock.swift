import AVFoundation
import CoreAudio
import CoreMedia
import os.lock

/// Shared presentation-timestamp derivation for every capture path.
///
/// System audio and the microphone are two independent Core Audio devices: a
/// private aggregate tap device and the input device. `mSampleTime` is each
/// device's own sample counter with an arbitrary origin — it starts when that
/// device was started by any client, and the two devices' nominal 48 kHz differ
/// by a few hundred ppm. Timestamping both tracks from it puts them on two
/// unrelated timelines that also drift apart for as long as the recording runs.
///
/// `mHostTime` is the machine-wide monotonic mach clock, which is exactly what
/// cross-device alignment needs, so it is preferred.
///
/// Measured before this change (2026-08-10, a 28.8-minute two-track recording):
/// the microphone track accumulated 1729.309 s while the system-audio track
/// accumulated 1728.565 s — 0.744 s apart, about 430 ppm. That divergence made
/// `AudioSegmentMerger` fail its duration check for any mic-enabled recording
/// longer than roughly four minutes, and it also meant the mixed-down audio put
/// the two voices on a timeline that slid apart.
///
/// The source is latched on the first buffer of a session and never changes
/// afterwards. A driver that reports a host time for most buffers but drops the
/// flag mid-stream would otherwise send the timestamp from mach time (~10⁵ s
/// since boot) down to a sample count (~10¹ s); `AVAssetWriterInput.append`
/// rejects non-monotonic audio timestamps, the writer latches `.failed`, and
/// the rest of that segment is silently dropped. One instance per capture
/// session — sharing one across sessions would carry a stale latch.
final class AudioCaptureClock: Sendable {
    private enum Source {
        case hostTime
        case sampleTime
    }

    private struct State {
        var source: Source?
        /// Last sample value emitted while latched to `.sampleTime`. A buffer
        /// that momentarily drops the sample-time flag must stay on the sample
        /// timeline: answering it from any host-derived clock (~10⁵ s since
        /// boot vs ~10¹ s of samples) would jump the writer forward, and the
        /// next flagged buffer would then jump it backwards — exactly the
        /// non-monotonic append that latches `AVAssetWriter` into `.failed`.
        var lastSampleValue: Int64?
    }

    /// Core Audio delivers on its own real-time thread; the state is read on
    /// every buffer and the latch is written once.
    private let latched = OSAllocatedUnfairLock<State>(initialState: State())

    func presentationTime(
        from timestamp: UnsafePointer<AudioTimeStamp>?,
        sampleRate: Double
    ) -> CMTime {
        guard let timestamp else {
            return CMClockGetTime(CMClockGetHostTimeClock())
        }
        let value = timestamp.pointee
        // A zero host time is treated as absent — some drivers set the flag
        // without filling the field.
        let hostTimeUsable = value.mFlags.contains(.hostTimeValid) && value.mHostTime != 0
        let sampleTimeUsable = value.mFlags.contains(.sampleTimeValid) && sampleRate > 0

        enum Resolution {
            case hostTime(UInt64)
            case sampleTime(Int64)
            case wallClock
        }

        let resolution = latched.withLock { state -> Resolution in
            if state.source == nil {
                state.source = hostTimeUsable ? .hostTime : (sampleTimeUsable ? .sampleTime : nil)
            }
            switch state.source {
            case .hostTime where hostTimeUsable:
                return .hostTime(value.mHostTime)
            case .sampleTime where sampleTimeUsable:
                let sample = Int64(value.mSampleTime.rounded())
                state.lastSampleValue = sample
                return .sampleTime(sample)
            case .sampleTime:
                // The flag dropped for this buffer. Nudge the last emitted
                // sample forward one unit: the writer needs strictly
                // increasing times, and staying on the sample timeline keeps
                // the next flagged buffer's real count a forward step instead
                // of a cross-clock jump back.
                if let last = state.lastSampleValue {
                    let nudged = last + 1
                    state.lastSampleValue = nudged
                    return .sampleTime(nudged)
                }
                return .wallClock
            default:
                // Host-time latch with the field missing: the wall clock is
                // the same mach timeline, so it moves forward continuously.
                return .wallClock
            }
        }

        switch resolution {
        case .hostTime(let hostTime):
            return CMClockMakeHostTimeFromSystemUnits(hostTime)
        case .sampleTime(let sample):
            return CMTime(
                value: sample,
                timescale: CMTimeScale(Int32(sampleRate.rounded()))
            )
        case .wallClock:
            return CMClockGetTime(CMClockGetHostTimeClock())
        }
    }
}
