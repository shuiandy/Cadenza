import Testing

@testable import Cadenza

@Suite("Detail load terminal state")
struct DetailLoadTrackerTests {
    @Test func latestMissingResultEndsLoadingAsUnavailable() {
        var tracker = DetailLoadTracker()
        let request = tracker.begin(hasContent: false)

        let accepted = tracker.finish(request: request, found: false)
        #expect(accepted)
        #expect(tracker.phase == .unavailable)
    }

    @Test func staleMissingResultCannotOverrideNewerSuccess() {
        var tracker = DetailLoadTracker()
        let stale = tracker.begin(hasContent: false)
        let current = tracker.begin(hasContent: false)

        let acceptedCurrent = tracker.finish(request: current, found: true)
        let acceptedStale = tracker.finish(request: stale, found: false)
        #expect(acceptedCurrent)
        #expect(!acceptedStale)
        #expect(tracker.phase == .content)
    }

    @Test func staleSuccessCannotResurrectContentAfterLatestMissing() {
        var tracker = DetailLoadTracker()
        let stale = tracker.begin(hasContent: false)
        let current = tracker.begin(hasContent: false)

        let acceptedCurrent = tracker.finish(request: current, found: false)
        let acceptedStale = tracker.finish(request: stale, found: true)
        #expect(acceptedCurrent)
        #expect(!acceptedStale)
        #expect(tracker.phase == .unavailable)
    }

    @Test func refreshKeepsExistingContentVisibleUntilLatestResult() {
        var tracker = DetailLoadTracker()
        let initial = tracker.begin(hasContent: false)
        let acceptedInitial = tracker.finish(request: initial, found: true)
        #expect(acceptedInitial)

        let refresh = tracker.begin(hasContent: true)

        #expect(tracker.phase == .content)
        let acceptedRefresh = tracker.finish(request: refresh, found: true)
        #expect(acceptedRefresh)
        #expect(tracker.phase == .content)
    }
}
