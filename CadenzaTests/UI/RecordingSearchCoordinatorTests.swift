import Foundation
import Testing

@testable import Cadenza

@MainActor
@Suite("Recording Search Coordinator")
struct RecordingSearchCoordinatorTests {
    @Test func rapidQueriesAreDebouncedToTheLatestRequest() async throws {
        let probe = SearchProbe()
        var received: [[RecordingDTO]] = []
        let coordinator = RecordingSearchCoordinator(
            debounceDelay: .milliseconds(50),
            search: { request in
                await probe.immediateResults(for: request)
            },
            receive: { received.append($0) }
        )

        coordinator.submit(.init(query: "f", sortKey: "dateNewest", folderID: nil, tagFilter: nil))
        try await Task.sleep(for: .milliseconds(10))
        coordinator.submit(.init(query: "final", sortKey: "dateNewest", folderID: nil, tagFilter: nil))

        try await waitUntil { received.count == 1 }

        #expect(await probe.queries == ["final"])
        #expect(received.first?.first?.title == "final")
    }

    @Test func cancelledSearchCannotOverwriteNewerResults() async throws {
        let probe = SearchProbe()
        var received: [[RecordingDTO]] = []
        let coordinator = RecordingSearchCoordinator(
            debounceDelay: .zero,
            search: { request in
                await probe.blockFirstResults(for: request)
            },
            receive: { received.append($0) }
        )

        coordinator.submit(.init(query: "first", sortKey: "dateNewest", folderID: nil, tagFilter: nil))
        await probe.waitUntilFirstStarted()

        coordinator.submit(.init(query: "second", sortKey: "dateNewest", folderID: nil, tagFilter: nil))
        try await waitUntil { received.first?.first?.title == "second" }

        await probe.releaseFirst()
        try await Task.sleep(for: .milliseconds(20))

        #expect(received.count == 1)
        #expect(received.first?.first?.title == "second")
    }

    @Test func blankQueryAndCancellationClearResultsAndRejectLateDelivery() async throws {
        let probe = SearchProbe()
        var received: [[RecordingDTO]] = [[TestDTOFactory.makeRecordingDTO(title: "existing")]]
        let coordinator = RecordingSearchCoordinator(
            debounceDelay: .zero,
            search: { request in
                await probe.blockFirstResults(for: request)
            },
            receive: { received.append($0) }
        )

        coordinator.submit(.init(query: "first", sortKey: "dateNewest", folderID: nil, tagFilter: nil))
        await probe.waitUntilFirstStarted()
        coordinator.submit(.init(query: "   ", sortKey: "dateNewest", folderID: nil, tagFilter: nil))

        #expect(received.last?.isEmpty == true)

        coordinator.cancel(clearResults: true)
        await probe.releaseFirst()
        try await Task.sleep(for: .milliseconds(20))

        #expect(received.last?.isEmpty == true)
        #expect(await probe.queries == ["first"])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for search result")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor SearchProbe {
    private(set) var queries: [String] = []
    private var firstStarted = false
    private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    func immediateResults(for request: RecordingSearchRequest) -> [RecordingDTO] {
        queries.append(request.query)
        return [TestDTOFactory.makeRecordingDTO(title: request.query)]
    }

    func blockFirstResults(for request: RecordingSearchRequest) async -> [RecordingDTO] {
        queries.append(request.query)
        if request.query == "first" {
            firstStarted = true
            firstStartedWaiters.forEach { $0.resume() }
            firstStartedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
        }
        return [TestDTOFactory.makeRecordingDTO(title: request.query)]
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            firstStartedWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }
}
