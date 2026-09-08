import Foundation
import Testing
@testable import Cadenza

@Suite("Speaker assignment sweep")
struct SpeakerAssignmentSweepTests {

    /// The original nested-loop algorithm, kept verbatim as the oracle.
    private static func reference(
        _ entries: [TranscriptEntry],
        spans: [SpeakerAssignmentSpan],
        replaceExistingSpeakers: Bool
    ) -> [TranscriptEntry] {
        let validSpans = spans.filter { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime }
        let firstAppearance = Dictionary(grouping: validSpans, by: \.speakerID)
            .mapValues { $0.map(\.startTime).min() ?? .greatestFiniteMagnitude }
        let ordered = firstAppearance.keys.sorted {
            let l = firstAppearance[$0] ?? .greatestFiniteMagnitude
            let r = firstAppearance[$1] ?? .greatestFiniteMagnitude
            if l != r { return l < r }
            return $0 < $1
        }
        let labels = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, "Speaker \($0.offset + 1)") })
        var result = entries
        for i in result.indices {
            let entry = result[i]
            if entry.speaker != nil && !replaceExistingSpeakers { continue }
            var overlapBySpeaker: [Int: TimeInterval] = [:]
            for span in validSpans {
                let overlap = max(0, min(entry.endTime, span.endTime) - max(entry.startTime, span.startTime))
                if overlap > 0 { overlapBySpeaker[span.speakerID, default: 0] += overlap }
            }
            let ranked = overlapBySpeaker.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let total = ranked.reduce(0) { $0 + $1.value }
            let top = ranked.first
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            let dominance = top.map { total > 0 ? $0.value / total : 0 } ?? 0
            let margin = top.map { $0.value - runnerUp } ?? 0
            let duration = max(0, entry.endTime - entry.startTime)
            let coverage = duration > 0 ? min(total, duration) / duration : 0
            let minimumMargin = min(0.20, max(0.02, total * 0.05))
            let confident = top != nil && coverage >= 0.20 && dominance >= 0.55 && margin >= minimumMargin
            let label = confident ? top.flatMap { labels[$0.key] } : nil
            result[i] = TranscriptEntry(startTime: entry.startTime, endTime: entry.endTime, text: entry.text,
                                        speaker: label ?? (replaceExistingSpeakers ? nil : entry.speaker))
        }
        return result
    }

    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    @Test func sweepMatchesTheNestedLoopOracleOnRandomTimelines() {
        var rng = LCG(state: 42)
        for trial in 0..<40 {
            let spanCount = 20 + Int(rng.next() * 300)
            let entryCount = 20 + Int(rng.next() * 200)
            let horizon = 600.0
            let spans: [SpeakerAssignmentSpan] = (0..<spanCount).map { _ in
                let start = rng.next() * horizon
                let length = 0.2 + rng.next() * (trial % 3 == 0 ? 60 : 8)   // some long, overlapping spans
                return SpeakerAssignmentSpan(speakerID: Int(rng.next() * 4), startTime: start, endTime: start + length)
            } + [SpeakerAssignmentSpan(speakerID: 9, startTime: 10, endTime: 5)]   // invalid, must be ignored
            let entries: [TranscriptEntry] = (0..<entryCount).map { i in
                let start = rng.next() * horizon
                let length = 0.5 + rng.next() * 12
                let existing: String? = i % 5 == 0 ? "A" : nil
                return TranscriptEntry(startTime: start, endTime: start + length, text: "e\(i)", speaker: existing)
            }
            for replace in [true, false] {
                let expected = Self.reference(entries, spans: spans, replaceExistingSpeakers: replace)
                let actual = SpeakerDiarizer.assignSpeakers(entries, spans: spans, replaceExistingSpeakers: replace)
                #expect(actual.map(\.speaker) == expected.map(\.speaker), "trial \(trial) replace=\(replace)")
                #expect(actual.map(\.text) == entries.map(\.text))
            }
        }
    }

    @Test func instanceWrapperAndOffMainPathAgree() async {
        let spans = [
            SpeakerAssignmentSpan(speakerID: 3, startTime: 0, endTime: 10),
            SpeakerAssignmentSpan(speakerID: 1, startTime: 10, endTime: 20),
        ]
        let entries = [
            TranscriptEntry(startTime: 1, endTime: 4, text: "one"),
            TranscriptEntry(startTime: 12, endTime: 15, text: "two"),
        ]
        let sweep = SpeakerDiarizer.assignSpeakers(entries, spans: spans, replaceExistingSpeakers: true)
        #expect(sweep.map(\.speaker) == ["Speaker 1", "Speaker 2"])   // canonical by first appearance
        var mutable = entries
        await MainActor.run {
            SpeakerDiarizer.shared.assignSpeakers(entries: &mutable, spans: spans, replaceExistingSpeakers: true)
        }
        #expect(mutable.map(\.speaker) == sweep.map(\.speaker))
    }
}
