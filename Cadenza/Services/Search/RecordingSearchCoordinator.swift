import Foundation

struct RecordingSearchRequest: Hashable, Sendable {
    let query: String
    let sortKey: String
    let folderID: UUID?
    let tagFilter: String?

    var isBlank: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Owns list-search scheduling so rapid keystrokes do not launch a full
/// SwiftData/transcript scan for every intermediate query.
@MainActor
final class RecordingSearchCoordinator {
    typealias Search = @Sendable (RecordingSearchRequest) async -> [RecordingDTO]
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias Receiver = @MainActor @Sendable ([RecordingDTO]) -> Void

    private let debounceDelay: Duration
    private let sleep: Sleeper
    private let search: Search
    private let receive: Receiver

    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(
        debounceDelay: Duration = .milliseconds(250),
        sleep: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        },
        search: @escaping Search,
        receive: @escaping Receiver
    ) {
        self.debounceDelay = debounceDelay
        self.sleep = sleep
        self.search = search
        self.receive = receive
    }

    func submit(_ request: RecordingSearchRequest) {
        generation &+= 1
        let requestGeneration = generation
        task?.cancel()

        guard !request.isBlank else {
            task = nil
            receive([])
            return
        }

        let debounceDelay = debounceDelay
        let sleep = sleep
        let search = search
        task = Task { [weak self] in
            do {
                try await sleep(debounceDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            let results = await search(request)
            guard !Task.isCancelled,
                  let self,
                  self.generation == requestGeneration else { return }

            self.receive(results)
            self.task = nil
        }
    }

    func cancel(clearResults: Bool) {
        generation &+= 1
        task?.cancel()
        task = nil
        if clearResults {
            receive([])
        }
    }
}
