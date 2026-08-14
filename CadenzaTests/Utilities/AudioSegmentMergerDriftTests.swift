import Foundation
import Testing
@testable import Cadenza

@Suite("Merge duration drift allowance")
struct AudioSegmentMergerDriftTests {
    /// A single-segment merge has no joins, so it keeps the original strictness.
    @Test func aMergeWithoutJoinsKeepsTheTightAllowance() {
        #expect(AudioSegmentMerger.driftAllowance(boundaries: 0) == 0.1)
        #expect(AudioSegmentMerger.driftAllowance(boundaries: 1) == 0.1)
        #expect(AudioSegmentMerger.durationsMatch(
            outputDuration: 30.05, expectedDuration: 30, boundaries: 0
        ))
        #expect(!AudioSegmentMerger.durationsMatch(
            outputDuration: 30.5, expectedDuration: 30, boundaries: 0
        ))
    }

    /// The case that stranded a real recording: 58 segments whose two tracks had
    /// drifted 0.76 s apart, rejected by the old flat 0.1 s allowance.
    @Test func acceptsTheDriftOfARealLongTwoTrackMerge() {
        let expected = 1728.5653
        let output = 1729.3213
        #expect(abs(output - expected) > 0.1, "precondition: the old allowance rejected this")
        #expect(AudioSegmentMerger.durationsMatch(
            outputDuration: output,
            expectedDuration: expected,
            boundaries: 57
        ))
    }

    /// Tying the allowance to joins rather than to wall-clock duration is the
    /// point: a long recording that was written as few segments stays strict, so
    /// a multi-second tail truncation cannot slip through.
    @Test func lengthAloneDoesNotRelaxTheGuard() {
        #expect(AudioSegmentMerger.driftAllowance(boundaries: 2) == 0.1)
        #expect(!AudioSegmentMerger.durationsMatch(
            outputDuration: 3_500, expectedDuration: 3_600, boundaries: 2
        ))
    }

    /// The guard must still do its job: a merge that silently dropped a whole
    /// segment is never within tolerance, at any segment count.
    @Test func neverToleratesADroppedSegment() {
        for segments in [4, 20, 58, 240, 2_000] {
            let allowance = AudioSegmentMerger.driftAllowance(boundaries: segments - 1)
            #expect(
                allowance < SegmentedAudioFileWriter.segmentDuration,
                "allowance \(allowance) would swallow a lost segment at \(segments) segments"
            )
            let expected = TimeInterval(segments) * SegmentedAudioFileWriter.segmentDuration
            #expect(!AudioSegmentMerger.durationsMatch(
                outputDuration: expected - SegmentedAudioFileWriter.segmentDuration,
                expectedDuration: expected,
                boundaries: segments - 1
            ))
        }
    }

    @Test func theAllowanceIsCappedAtHalfASegment() {
        #expect(
            AudioSegmentMerger.driftAllowance(boundaries: 100_000)
                == SegmentedAudioFileWriter.segmentDuration / 2
        )
    }

    @Test func negativeBoundaryCountsAreTreatedAsNone() {
        #expect(AudioSegmentMerger.driftAllowance(boundaries: -5) == 0.1)
    }

    @Test func rejectsNonFiniteAndNonPositiveDurations() {
        #expect(!AudioSegmentMerger.durationsMatch(
            outputDuration: .nan, expectedDuration: 100, boundaries: 10
        ))
        #expect(!AudioSegmentMerger.durationsMatch(
            outputDuration: 100, expectedDuration: .infinity, boundaries: 10
        ))
        #expect(!AudioSegmentMerger.durationsMatch(
            outputDuration: 0, expectedDuration: 100, boundaries: 10
        ))
        #expect(!AudioSegmentMerger.durationsMatch(
            outputDuration: 100, expectedDuration: 0, boundaries: 10
        ))
    }
}
