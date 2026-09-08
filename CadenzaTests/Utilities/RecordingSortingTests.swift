import Foundation
import Testing
@testable import Cadenza

@Suite("Recording sorting and library memo")
struct RecordingSortingTests {

    private func dto(_ title: String, start: TimeInterval, accessed: TimeInterval? = nil) -> RecordingDTO {
        RecordingDTO(
            id: UUID(), title: title, startDate: Date(timeIntervalSince1970: start), endDate: nil,
            duration: 60, meetingApp: nil, meetingURL: nil, language: "en", tags: [], meetingType: nil,
            lastAccessedDate: accessed.map { Date(timeIntervalSince1970: $0) }, trashedDate: nil,
            folderID: nil, linkedCalendarEventID: nil, hasTranscript: false, hasSummary: false,
            transcriptPreview: nil, summaryPreview: nil, audioFile: nil
        )
    }

    @Test func everySortKeyOrdersAsBefore() {
        let a = dto("banana", start: 10, accessed: 5)
        let b = dto("Apple", start: 30, accessed: nil)
        let c = dto("cherry", start: 20, accessed: 50)
        let all = [a, b, c]
        #expect(RecordingSorting.sort(all, by: "dateNewest").map(\.title) == ["Apple", "cherry", "banana"])
        #expect(RecordingSorting.sort(all, by: "unknown-key").map(\.title) == ["Apple", "cherry", "banana"])
        #expect(RecordingSorting.sort(all, by: "dateOldest").map(\.title) == ["banana", "cherry", "Apple"])
        #expect(RecordingSorting.sort(all, by: "recentlyAccessed").map(\.title) == ["cherry", "banana", "Apple"])
        #expect(RecordingSorting.sort(all, by: "nameAZ").map(\.title) == ["Apple", "banana", "cherry"])
        #expect(RecordingSorting.sort(all, by: "nameZA").map(\.title) == ["cherry", "banana", "Apple"])
    }

    @Test func memoRecomputesOnlyWhenTheTokenOrKeyChanges() {
        var memo = TokenKeyedMemo()
        var calls = 0
        func compute() -> Int { calls += 1; return calls }

        #expect(memo.value(token: 1, key: "a", compute: compute) == 1)
        #expect(memo.value(token: 1, key: "a", compute: compute) == 1)   // cached
        #expect(memo.value(token: 1, key: "b", compute: compute) == 2)   // different key
        #expect(memo.value(token: 2, key: "a", compute: compute) == 3)   // token moved
        #expect(memo.value(token: 2, key: "a", compute: compute) == 3)
        #expect(memo.computeCount == 3)
        // A type mismatch for the same key never returns a wrong value.
        #expect(memo.value(token: 2, key: "a") { "string" } == "string")
    }
}
