import AVFoundation
import CoreAudio
import CoreMedia
import Testing
@testable import Cadenza

@Suite("Audio capture clock")
struct AudioCaptureClockTests {
    private func timestamp(
        sampleTime: Float64,
        hostTime: UInt64,
        flags: AudioTimeStampFlags
    ) -> AudioTimeStamp {
        var value = AudioTimeStamp()
        value.mSampleTime = sampleTime
        value.mHostTime = hostTime
        value.mFlags = flags
        return value
    }

    private func resolve(
        _ clock: AudioCaptureClock,
        sampleTime: Float64,
        hostTime: UInt64,
        flags: AudioTimeStampFlags,
        sampleRate: Double = 48_000
    ) -> CMTime {
        var value = timestamp(sampleTime: sampleTime, hostTime: hostTime, flags: flags)
        return withUnsafePointer(to: &value) {
            clock.presentationTime(from: $0, sampleRate: sampleRate)
        }
    }

    /// The regression this file exists for: two capture devices each report a
    /// sample counter with its own origin, so preferring `mSampleTime` put the
    /// microphone and system-audio tracks on unrelated timelines.
    @Test func prefersHostTimeOverSampleTime() {
        let resolved = resolve(
            AudioCaptureClock(),
            sampleTime: 48_000,
            hostTime: 1_000_000,
            flags: [.sampleTimeValid, .hostTimeValid]
        )
        #expect(resolved == CMClockMakeHostTimeFromSystemUnits(1_000_000))
        // Sample time would have produced exactly one second; host time must not.
        #expect(resolved != CMTime(value: 48_000, timescale: 48_000))
    }

    @Test func fallsBackToSampleTimeWhenNoHostTimeIsReported() {
        let resolved = resolve(
            AudioCaptureClock(),
            sampleTime: 96_000,
            hostTime: 0,
            flags: [.sampleTimeValid]
        )
        #expect(resolved == CMTime(value: 96_000, timescale: 48_000))
    }

    /// Some drivers set the flag without filling the field; a zero host time
    /// would otherwise rebase every buffer to the epoch.
    @Test func ignoresZeroHostTime() {
        let resolved = resolve(
            AudioCaptureClock(),
            sampleTime: 24_000,
            hostTime: 0,
            flags: [.sampleTimeValid, .hostTimeValid]
        )
        #expect(resolved == CMTime(value: 24_000, timescale: 48_000))
    }

    @Test func bothDevicesResolveIdenticallyForTheSameHostTime() {
        // Different sample counters, same host clock reading: the two devices
        // must still land on the same presentation time.
        let mic = resolve(
            AudioCaptureClock(),
            sampleTime: 1_000_000,
            hostTime: 42_000_000,
            flags: [.sampleTimeValid, .hostTimeValid]
        )
        let system = resolve(
            AudioCaptureClock(),
            sampleTime: 7,
            hostTime: 42_000_000,
            flags: [.sampleTimeValid, .hostTimeValid],
            sampleRate: 44_100
        )
        #expect(mic == system)
    }

    /// A driver that stops reporting host time mid-stream must not send the
    /// timeline backwards: `AVAssetWriterInput` rejects non-monotonic audio
    /// timestamps and drops the rest of the segment once it latches `.failed`.
    @Test func aLatchedHostTimeNeverFallsBackToSampleTime() {
        let clock = AudioCaptureClock()
        let first = resolve(
            clock,
            sampleTime: 0,
            hostTime: 500_000_000,
            flags: [.sampleTimeValid, .hostTimeValid]
        )
        let afterHostTimeDisappears = resolve(
            clock,
            sampleTime: 48_000,
            hostTime: 0,
            flags: [.sampleTimeValid]
        )
        #expect(afterHostTimeDisappears != CMTime(value: 48_000, timescale: 48_000))
        #expect(afterHostTimeDisappears.seconds > first.seconds - 1)
    }

    /// The mirror case: a session that started on sample time keeps using it
    /// even once the driver starts reporting a (much larger) host time.
    @Test func aLatchedSampleTimeIgnoresALaterHostTime() {
        let clock = AudioCaptureClock()
        _ = resolve(clock, sampleTime: 0, hostTime: 0, flags: [.sampleTimeValid])
        let later = resolve(
            clock,
            sampleTime: 96_000,
            hostTime: 900_000_000,
            flags: [.sampleTimeValid, .hostTimeValid]
        )
        #expect(later == CMTime(value: 96_000, timescale: 48_000))
    }

    /// A sample-time latch must survive a buffer that momentarily drops the
    /// flag: answering it from any host-derived clock would jump the timeline
    /// forward by ~10⁵ seconds, and the next flagged buffer's real sample
    /// count would then jump it backwards — the exact non-monotonic append
    /// that latches `AVAssetWriter` into `.failed`.
    @Test func aLatchedSampleTimeStaysOnTheSampleTimelineThroughAFlagDropout() {
        let clock = AudioCaptureClock()
        let first = resolve(clock, sampleTime: 48_000, hostTime: 0, flags: [.sampleTimeValid])
        #expect(first == CMTime(value: 48_000, timescale: 48_000))

        // Flag dropout: stay on the sample timeline, strictly increasing.
        let dropout = resolve(clock, sampleTime: 0, hostTime: 900_000_000, flags: [.hostTimeValid])
        #expect(dropout == CMTime(value: 48_001, timescale: 48_000))

        // Recovery lands forward of the dropout, never backwards.
        let recovered = resolve(clock, sampleTime: 49_024, hostTime: 0, flags: [.sampleTimeValid])
        #expect(recovered == CMTime(value: 49_024, timescale: 48_000))
        #expect(recovered > dropout)
    }

    /// The latch belongs to one capture session; a new instance re-decides.
    @Test func aNewInstanceLatchesIndependently() {
        let sampleFirst = AudioCaptureClock()
        _ = resolve(sampleFirst, sampleTime: 0, hostTime: 0, flags: [.sampleTimeValid])

        let hostFirst = AudioCaptureClock()
        let resolved = resolve(
            hostFirst,
            sampleTime: 48_000,
            hostTime: 700_000_000,
            flags: [.sampleTimeValid, .hostTimeValid]
        )
        #expect(resolved == CMClockMakeHostTimeFromSystemUnits(700_000_000))
    }

    @Test func aMissingTimestampFallsBackToTheHostClock() {
        let resolved = AudioCaptureClock()
            .presentationTime(from: nil, sampleRate: 48_000)
        #expect(resolved.isValid)
        #expect(resolved.seconds > 0)
    }
}
