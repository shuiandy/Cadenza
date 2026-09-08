import Foundation

/// Debounced, loss-free queue of recordings whose markdown mirror needs a
/// refresh.
///
/// Saves arrive faster than the mirror can render. The debounce coalesces
/// them, but a refresh that has already taken its batch must never be cancelled
/// by the next save: those ids would be dropped and the mirror left stale until
/// the recording changed again (the old whole-library pass hid this because it
/// rewrote everything each time). Only the not-yet-started debounce restarts;
/// a drain in flight finishes its batch and then picks up whatever arrived.
@MainActor
final class MarkdownMirrorRefreshQueue {
    private var pending: Set<UUID> = []
    private var debounceTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private let debounce: Duration
    private let refresh: (Set<UUID>) async -> Void

    init(debounce: Duration = .milliseconds(500), refresh: @escaping (Set<UUID>) async -> Void) {
        self.debounce = debounce
        self.refresh = refresh
    }

    var pendingIDs: Set<UUID> { pending }
    var isDraining: Bool { drainTask != nil }

    func enqueue(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pending.formUnion(ids)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .zero)
            guard !Task.isCancelled else { return }
            self?.startDrainIfNeeded()
        }
    }

    /// Teardown only (profile switch, reconfiguration). Drops pending work
    /// deliberately: the next configuration owns a different directory.
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        drainTask?.cancel()
        drainTask = nil
        pending = []
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }   // the running drain loops over new ids itself
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { drainTask = nil }
        while !pending.isEmpty, !Task.isCancelled {
            let batch = pending
            pending = []
            await refresh(batch)
        }
    }
}
