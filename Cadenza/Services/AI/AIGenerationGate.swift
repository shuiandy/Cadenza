import Foundation

/// 进程级 async 串行闸:同一时刻至多一个 AI 生成调用(prep / summary / recap 共用),
/// 防止并发打爆 provider。用 continuation 队列实现串行,避免 actor reentrancy。
actor AIGenerationGate {
    static let shared = AIGenerationGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()  // busy stays true — handed to next
        }
    }
}
